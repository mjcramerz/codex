The automatically generated patch by dpkg-source(1) puts this free form text on
top of it.

This is normally for the non-native Debian packaging.

Whenever possible, use this instead of debian/patch-header to make dpkg-source
long options applied for the team builds based on the VCS repository while NMU
builds based on the Debian source package are not affected.

== Patch applied strategy (merge) ==

The source outside of debian/ directory is modified by maintainer and
different from the upstream one:
  * Workflow using dpkg-source commit (commit all to VCS after dpkg-source commit)
      https://www.debian.org/doc/manuals/debmake-doc/ch04.en.html#dpkg-source-commit
  * Workflow described in dgit-maint-merge(7)

Keep this file after updating its content if you use this strategy

== Other strategies ==

Remove this file if you use this strategy

===

A single combined diff, containing all the changes, follows.
