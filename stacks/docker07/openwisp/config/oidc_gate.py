# Mounted next to custom_django_settings.py (dashboard, which serves the login). Keycloak logins need the group `openwisp` in the `groups`
# claim: in realm `chat`, logins through the member broker and self-registrations never run the client's gate flow.
# Group members become staff (Django admin access) and get an organization of their own at login (created once): the user is
# its admin and owner and in the Django group Administrator, so they manage their devices and the users of their organization.
# Nothing is removed or migrated: existing memberships stay, superusers are left alone.
# A user who is no longer in `openwisp` loses the Django groups and all memberships except ownerships when the login is refused
# (superusers excepted); no organization is created for refused users and none is deleted.
import logging
import re

from allauth.core.exceptions import ImmediateHttpResponse
from allauth.socialaccount.adapter import DefaultSocialAccountAdapter
from django.http import HttpResponseForbidden

GROUP = "openwisp"
PERSONAL_GROUP = "Administrator"  # needed to add users to the own organization; scoped to the organizations the user manages
DJANGO_GROUPS = ("Operator", "Administrator")
log = logging.getLogger(__name__)


def claim_groups(extra_data):
    groups = set()
    for part in ("userinfo", "id_token"):
        claim = (extra_data.get(part) or {}).get("groups") or []
        groups.update([claim] if isinstance(claim, str) else claim)
    return groups


def allowed(groups):
    return GROUP in groups or "/" + GROUP in groups


def free_slug(username, taken):
    """Slug for the personal organization: lowercase, [a-z0-9-] only, `-2`, `-3` ... while taken(slug)."""
    base = re.sub(r"[^a-z0-9]+", "-", username.lower()).strip("-")[:150] or "user"
    slug, n = base, 1
    while taken(slug):
        n += 1
        slug = "%s-%d" % (base, n)
    return slug


def ensure_personal_org(user):
    from django.contrib.auth.models import Group
    from django.db import IntegrityError, transaction
    from openwisp_users.models import Organization, OrganizationOwner, OrganizationUser

    if user.is_superuser:
        return
    marker = "Personal organization of user %s" % user.pk
    with transaction.atomic():
        org = Organization.objects.filter(description=marker).first()
        while org is None:
            slug = free_slug(
                user.username, lambda s: Organization.objects.filter(slug=s).exists()
            )
            try:
                with transaction.atomic():
                    org = Organization.objects.create(
                        name=user.username, slug=slug, description=marker
                    )
            except IntegrityError:  # slug taken meanwhile
                org = None
        # is_admin is what lets a staff user see the organization's objects; a signal makes the first admin owner, made sure here
        ou, _ = OrganizationUser.objects.update_or_create(
            user=user, organization=org, defaults={"is_admin": True}
        )
        OrganizationOwner.objects.get_or_create(
            organization=org, defaults={"organization_user": ou}
        )
        group = Group.objects.filter(name=PERSONAL_GROUP).first()
        if group is None:
            log.warning(
                "Django group %s missing: its permissions cannot be granted",
                PERSONAL_GROUP,
            )
        else:
            user.groups.add(group)


def revoke_user(user):
    """Refused at login: drop the Operator/Administrator groups and memberships that are not ownerships (not for superusers)."""
    from openwisp_users.models import OrganizationUser

    if user.is_superuser:
        return
    OrganizationUser.objects.filter(user=user, organizationowner__isnull=True).delete()
    user.groups.remove(*user.groups.filter(name__in=DJANGO_GROUPS))


class GroupGateAdapter(DefaultSocialAccountAdapter):
    def pre_social_login(self, request, sociallogin):
        if not allowed(claim_groups(sociallogin.account.extra_data or {})):
            if sociallogin.is_existing:
                revoke_user(sociallogin.user)
            raise ImmediateHttpResponse(
                HttpResponseForbidden(
                    "OpenWISP is for members of the group %s. Ask the FFMUC admins.\n"
                    % GROUP,
                    content_type="text/plain",
                )
            )
        user = sociallogin.user
        if (
            user.pk
        ):  # linked account, or an existing user matched by e-mail (allauth looked it up before this hook)
            if not user.is_staff:
                user.is_staff = True
                user.save(update_fields=["is_staff"])
            ensure_personal_org(user)
        super().pre_social_login(request, sociallogin)

    def populate_user(self, request, sociallogin, data):
        user = super().populate_user(request, sociallogin, data)
        user.is_staff = True
        return user

    def save_user(self, request, sociallogin, form=None):
        user = super().save_user(request, sociallogin, form)
        ensure_personal_org(user)
        return user
