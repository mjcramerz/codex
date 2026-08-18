The automatically generated patch by dpkg-source(1) puts this free form text on
top of it.

This is normally for the non-native Debian packaging.

Whenever possible, use debian/local-patch-header instead to make dpkg-source long
options applied for the team builds based on the VCS repository while NMU
builds based on the Debian source package are not affected.

A single combined diff, containing all the changes, follows.

===
