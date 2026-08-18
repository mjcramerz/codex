"""Rules for building release binaries across supported target platforms."""

load("@rules_platform//platform_data:defs.bzl", "platform_data")

PLATFORM_TARGETS = {
    "linux_amd64_gnu": "@llvm//platforms:linux_amd64",
}

PLATFORMS = [
    "linux_arm64_musl",
    "linux_amd64_musl",
    "macos_amd64",
    "macos_arm64",
    "windows_amd64",
    "windows_arm64",
]

def platform_binary(name, target, platform):
    platform_data(
        name = name,
        platform = PLATFORM_TARGETS.get(platform, "@llvm//platforms:" + platform),
        target = target,
        tags = ["manual"],
    )

def multiplatform_binaries(name, platforms = PLATFORMS):
    for platform in platforms:
        platform_binary(
            name = name + "_" + platform,
            target = name,
            platform = platform,
        )

    native.filegroup(
        name = "release_binaries",
        srcs = [name + "_" + platform for platform in platforms],
        tags = ["manual"],
    )
