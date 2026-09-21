# docker-containers

Compose stacks managed by Salt. The `docker` state installs the engine and the
`docker-compose-plugin`; everything here drives `docker compose` (v2).

Not currently in `top.sls`. To roll it out, add `- docker-containers` next to
`- docker` for the relevant targets. Every stack gates itself on Netbox
config_context, so adding it to `top.sls` only deploys the stacks you enable.

## Adding a stack

One directory per stack:

    docker-containers/<name>/
      init.sls
      docker-compose.yml.j2

Follow the shape used by `diun/` and `speedtest/` (and `packetyeeter/` outside
this directory):

```yaml
{% if salt["pillar.get"]("netbox:config_context:docker:<name>:enabled", False) %}

/srv/docker/<name>:
  file.directory:
    - user: root
    - group: root
    - mode: "0755"
    - makedirs: True

/srv/docker/<name>/docker-compose.yml:
  file.managed:
    - source: salt://docker-containers/<name>/docker-compose.yml.j2
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"
    - require:
      - file: /srv/docker/<name>

<name>-compose:
  cmd.run:
    - name: docker compose pull && docker compose up -d --remove-orphans
    - cwd: /srv/docker/<name>
    - require:
      - file: /srv/docker/<name>/docker-compose.yml
    - onchanges:
      - file: /srv/docker/<name>/docker-compose.yml
{% endif %}
```

Then add `- docker-containers.<name>` to `init.sls`.

## Conventions

- **`docker compose`, never `docker-compose`.** The v1 binary is explicitly
  removed by the `docker` state (`/usr/local/bin/docker-compose: file.absent`).
- **No `version:` key** in compose files. It has been obsolete since Compose v2
  and only produces a warning.
- **`onchanges` on the managed files**, so a highstate does not restart
  containers on every run.
- **`mode: "0600"` for any file holding a credential** (webhook URLs, DB
  passwords). Do not put secrets in a world-readable compose file; prefer
  pulling them from config_context into a 0600 env file.
- **Directories are `0755`/`0750`, never `0757`.** The old loop in this
  directory created world-writable container data directories.
- **Pin image tags** where a surprise upgrade would hurt. `:latest` combined
  with a mounted `docker.sock` means an upstream compromise is root on the host.

## History

Until this rewrite, `init.sls` drove every stack from one config_context loop
via `module.run: dockercompose.build` / `dockercompose.up`. That Salt module was
a wrapper around the Python `docker-compose` v1 library and has since been
removed from Salt, so the loop could not work. The state had been commented out
of `top.sls` since December 2020.

## Reference compose files

The `*-compose.yml` files at the top of this directory (cfssl, graylog,
mattermost, netbox, openldap, zammad) are **not deployed by Salt**. They are
kept as a record of how those services were set up, for recovery and for other
communities building on this repo. Image versions in them date from
2019/2020 and should not be used as-is.
