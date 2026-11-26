package trivy

import rego.v1

default ignore := false

# Kernel headers: no kernel runs in a container, the CVEs are not reachable.
ignore if input.PkgName == "linux-libc-dev"
