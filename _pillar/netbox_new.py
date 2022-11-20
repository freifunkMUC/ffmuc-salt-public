from __future__ import absolute_import, print_function, unicode_literals
import logging
import six

# Import Salt libs
import salt.utils.http

log = logging.getLogger(__name__)


def ext_pillar_test(minion_id, pillar, *args, **kwargs):
    api_url = kwargs["api_url"].rstrip("/").rstrip("/api") + "/graphql/"
    api_token = kwargs.get("api_token")
    headers = {}
    if api_token:
        headers = {"Authorization": f"Token {api_token}"}

    # TODO: http call
    # TODO: Transform device_list and virtualmachine to "instance" or similar
    # TODO: Move site to root (to make it uniform) opt if ^ is done
    graphql = """
        {
            device_list(name: "guardian-muc01.in.ffmuc.net", status: "ACTIVE") {
                id
                name
                device_role {
                    id
                    slug
                }
                config_context
                primary_ip4 {
                    address
                }
                primary_ip6 {
                    address
                }
                interfaces {
                    name
                    tags {
                        slug
                    }
                    custom_fields
                    ip_addresses {
                        tags {
                        slug
                        }
                        address
                        status
                        role
                        custom_fields
                    }
                }
                site {
                    name
                    slug
                    prefixes {
                        prefix
                    }
                }
                tags {
                    
                }
            }
            virtual_machine_list(name: "webfrontend03.in.ffmuc.net", status: "ACTIVE") {
                id
                name
                role {
                    slug
                }
                cluster {
                    site {
                        name
                        slug
                        prefixes {
                            prefix
                        }
                    }
                }
                primary_ip4 {
                    address
                }
                primary_ip6 {
                    address
                }
                interfaces {
                    name
                    tags {
                        slug
                    }
                    custom_fields
                    ip_addresses {
                        tags {
                            slug
                        }
                        address
                        status
                        role
                        custom_fields
                    }
                }
                tags {
                    slug
                }
            }
            service_list {
                id
                name
                device {
                    name
                    interfaces {
                        id
                        name
                        tags {
                            slug
                        }
                        device {
                            id
                        }
                    }
                }
                protocol
                ports
                ipaddresses {
                    id
                    tags {
                        id
                        slug
                    }
                    address
                    status
                    role
                    custom_fields
                }
                custom_fields
            }
        }
    """
    response = salt.utils.http.query(
        api_url, method="POST", data=graphql, header_dict=headers, decode=True
    )
