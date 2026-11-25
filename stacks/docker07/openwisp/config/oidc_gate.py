# Mounted next to custom_django_settings.py (dashboard, which serves the login). Keycloak logins need the group `openwisp` in the `groups`
# claim: in realm `chat`, logins through the member broker and self-registrations never run the client's gate flow.
# Group members become staff (Django admin access). Access per organization follows the group paths in the claim (full.path on):
#   /openwisp                    may log in, no organization
#   /openwisp/<org-slug>         manages the organization <org-slug> (Django group Operator)
#   /openwisp/<org-slug>/admin   same, plus user management (Django group Administrator)
# The Django groups are global: Administrator only for a user who is /admin in every organization they get, else Operator.
# Each login makes OrganizationUser and the two Django groups match the claim. Superusers, organization owners and organizations
# that do not exist are left alone; organizations are created by ops/ffmuc-openwisp-site-orgs.sh, never from the claim.
# A user who is no longer in `openwisp` loses memberships and groups when the login is refused (superusers and owners excepted).
# The old claim format (bare group name, full.path off) still opens the gate but syncs nothing.
import logging
import re

from allauth.core.exceptions import ImmediateHttpResponse
from allauth.socialaccount.adapter import DefaultSocialAccountAdapter
from django.http import HttpResponseForbidden

GROUP = "openwisp"
DJANGO_GROUPS = ("Operator", "Administrator")  # model permissions; the organizations scope them through OrganizationUser
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]*$")
log = logging.getLogger(__name__)


def claim_groups(extra_data):
    groups = set()
    for part in ("userinfo", "id_token"):
        claim = (extra_data.get(part) or {}).get("groups") or []
        groups.update([claim] if isinstance(claim, str) else claim)
    return groups


def parse_groups(groups):
    """-> (allowed, sync, orgs); orgs: slug -> True for /openwisp/<slug>/admin; sync: the claim carries paths."""
    sync = any(g.startswith("/") for g in groups)
    allowed = GROUP in groups or "/" + GROUP in groups or any(g.startswith("/%s/" % GROUP) for g in groups)
    orgs = {}
    for g in groups:
        parts = g.split("/")
        if len(parts) < 3 or parts[:2] != ["", GROUP] or not SLUG.match(parts[2]):
            continue
        if len(parts) == 3:
            orgs.setdefault(parts[2], False)
        elif len(parts) == 4 and parts[3] == "admin":
            orgs[parts[2]] = True
    return allowed, sync, orgs


def wanted_group(orgs, known):
    """Django group for the organizations that exist (known); None without any."""
    if not known:
        return None
    return "Administrator" if all(orgs[slug] for slug in known) else "Operator"


def sync_user(user, orgs):
    from django.contrib.auth.models import Group
    from django.db import transaction
    from openwisp_users.models import Organization, OrganizationUser

    if user.is_superuser:
        return
    with transaction.atomic():
        known = {o.slug: o for o in Organization.objects.filter(slug__in=orgs)}
        for slug in sorted(set(orgs) - set(known)):
            log.warning("openwisp group for unknown organization %r ignored", slug)
        # is_admin is what lets a staff user see and change the organization's objects (organizations_managed): always set
        for org in known.values():
            OrganizationUser.objects.update_or_create(user=user, organization=org, defaults={"is_admin": True})
        OrganizationUser.objects.filter(user=user, organizationowner__isnull=True).exclude(
            organization__in=list(known.values())
        ).delete()
        # the Django groups are global: Administrator only if the user is /admin in every organization they get, else Operator
        want = wanted_group(orgs, known)
        present = {g.name: g for g in Group.objects.filter(name__in=DJANGO_GROUPS)}
        for name in DJANGO_GROUPS:
            if name not in present:
                log.warning("Django group %s missing: its permissions cannot be synced", name)
        for group in present.values():
            if group.name == want:
                user.groups.add(group)
            else:
                user.groups.remove(group)


def revoke_user(user):
    """Rejected at login: drop organization memberships and the Operator/Administrator groups (not for superusers and owners)."""
    from openwisp_users.models import OrganizationOwner, OrganizationUser

    if user.is_superuser or OrganizationOwner.objects.filter(organization_user__user=user).exists():
        return
    OrganizationUser.objects.filter(user=user).delete()
    user.groups.remove(*user.groups.filter(name__in=DJANGO_GROUPS))


class GroupGateAdapter(DefaultSocialAccountAdapter):
    def pre_social_login(self, request, sociallogin):
        allowed, sync, orgs = parse_groups(claim_groups(sociallogin.account.extra_data or {}))
        if not allowed:
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
        if user.pk:  # linked account, or an existing user matched by e-mail (allauth looked it up before this hook)
            if not user.is_staff:
                user.is_staff = True
                user.save(update_fields=["is_staff"])
            if sync:
                sync_user(user, orgs)
        super().pre_social_login(request, sociallogin)

    def populate_user(self, request, sociallogin, data):
        user = super().populate_user(request, sociallogin, data)
        user.is_staff = True
        return user

    def save_user(self, request, sociallogin, form=None):
        user = super().save_user(request, sociallogin, form)
        _, sync, orgs = parse_groups(claim_groups(sociallogin.account.extra_data or {}))
        if sync:
            sync_user(user, orgs)
        return user
