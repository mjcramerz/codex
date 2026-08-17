# Uncomment to active options. See dpkg-source(1)
#
# This file contains a list of long options that should be automatically
# prepended to the set of command line options of a dpkg-source --build call.

# This is normally for the non-native Debian packaging.

# Whenever possible, use this instead of debian/local-options to make
# dpkg-source long options applied for the team builds based on the VCS
# repository while NMU builds based on the Debian source package are not
# affected.

# == Patch unapplied strategy (dquilt, gbp, ...) ==
#
# The source outside of debian/ directory is unmodified from the upstream one:
#   * Workflow using diff -u
#       https://www.debian.org/doc/manuals/debmake-doc/ch04.en.html#diff-u
#   * Workflow using dquilt
#       https://www.debian.org/doc/manuals/debmake-doc/ch04.en.html#dquilt
#   * Workflow using dpkg-source commit (commit only patch to VCS after dpkg-source commit)
#       https://www.debian.org/doc/manuals/debmake-doc/ch04.en.html#dpkg-source-commit
#   * Workflow to use gbp-buildpackage(1) with pristine-tar
#   * Workflow described in dgit-maint-gbp(7)
#
# Uncomment following if you use this strategy
#abort-on-upstream-changes
#unapply-patches

# == Patch applied strategy (merge) ==
#
# The source outside of debian/ directory is modified by maintainer and
# different from the upstream one:
#   * Workflow using dpkg-source commit (commit all to VCS after dpkg-source commit)
#       https://www.debian.org/doc/manuals/debmake-doc/ch04.en.html#dpkg-source-commit
#   * Workflow described in dgit-maint-merge(7)
#
# uncomment following if you use this strategy
#single-debian-patch
#auto-commit

# == Patch applied strategy (debrebase) ==
#
# The source outside of debian/ directory is modified by maintainer and
# different from the upstream one:
#   * Workflow described in dgit-maint-debrebase(7)
#
# Remove this file if you use this strategy
