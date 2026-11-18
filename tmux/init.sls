#
# tmux magic
#

tmux:
  pkg.installed:
    - name: tmux

/root/.tmux.conf:
  file.absent

/etc/tmux.conf:
  file.managed:
    - source: salt://tmux/tmux.conf
