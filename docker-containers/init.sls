#
# Docker containers
#
# Each stack lives in its own subdirectory with a docker-compose.yml.j2 and an
# init.sls, and gates itself on netbox:config_context:docker:<stack>:enabled.
# See README.md in this directory for the pattern.
#
# The previous version of this file drove every stack from a single
# config_context loop via `module.run: dockercompose.up`. That Salt module was
# built on the Python docker-compose v1 library and no longer exists, so the
# loop could not have worked since well before this state was last enabled.
#

include:
  - docker-containers.diun
  - docker-containers.speedtest
