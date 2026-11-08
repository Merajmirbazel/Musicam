#!/usr/bin/env python3
"""Writes Musicam.xcodeproj without any third-party generator.

Uses Xcode's folder-synchronized groups, so any file added to App-macOS/ or App-iOS/ is part of
the target automatically; shared code lives in the local package MusicamKit. Re-run after
changing targets, settings or the package products listed below.
"""
import hashlib, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ = os.path.join(ROOT, "Musicam.xcodeproj")
BUNDLE_ID = "com.merajmirbazel.musicam"
PACKAGE_PRODUCTS = ["Features"]          # products of MusicamKit linked into both apps


def oid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


def q(v):
    s = str(v)
    return s if re.fullmatch(r"[A-Za-z0-9_./]+", s) else '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def settings(d, ind):
    out = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            out.append(f"{ind}{k} = (\n" + "".join(f"{ind}\t{q(x)},\n" for x in v) + f"{ind});")
        else:
            out.append(f"{ind}{k} = {q(v)};")
    return "\n".join(out)


common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_MODULES": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": "6.0",
}
project_cfg = {
    "Debug": {**common, "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "ONLY_ACTIVE_ARCH": "YES",
              "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"},
    "Release": {**common, "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule",
                "VALIDATE_PRODUCT": "YES"},
}

app_common = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_CFBundleDisplayName": "Musicam",
    "INFOPLIST_KEY_NSHumanReadableCopyright": "Copyright 2026 Meraj Mirbazel",
    "MARKETING_VERSION": "0.13.0",
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": "Musicam",
    "SWIFT_VERSION": "6.0",
}
TARGETS = [
    dict(name="Musicam-macOS", dir="App-macOS", settings={
        **app_common,
        "CODE_SIGN_ENTITLEMENTS": "Config/macOS.entitlements",
        "COMBINE_HIDPI_IMAGES": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",   # the Merajfy helper copy/sign script must read Helpers/ and run codesign
        "INFOPLIST_FILE": "Config/macOS-Info.plist",
        "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.music",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
        "MACOSX_DEPLOYMENT_TARGET": "15.0",
        "SDKROOT": "macosx",
    }),
    dict(name="Musicam-iOS", dir="App-iOS", settings={
        **app_common,
        "INFOPLIST_FILE": "Config/iOS-Info.plist",
        "DEVELOPMENT_TEAM": "9VF66R9227",   # the owner's Personal Team, so Xcode does not ask for a team after each regeneration
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        # Python + yt-dlp run inside the iPhone app (see Vendor/Python and App-iOS/OnDevicePython.swift)
        "SWIFT_OBJC_BRIDGING_HEADER": "Config/iOS-Bridging-Header.h",
        "HEADER_SEARCH_PATHS": "$(BUILT_PRODUCTS_DIR)/Python.framework/Headers",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",   # the Python install step copies the standard library and signs its extension modules
        "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }),
]

PY = {k: oid("py-" + k) for k in ("xcfw", "app", "pkgs", "xcfw-fw", "xcfw-embed", "app-bf", "pkgs-bf", "script", "embed")}
PY_FILES = [("xcfw", "Python.xcframework", "wrapper.xcframework", "Vendor/Python/Python.xcframework"),
            ("app", "app", "folder", "Vendor/Python/app"),
            ("pkgs", "app_packages", "folder", "Vendor/Python/app_packages")]
PY_SCRIPT_SOURCE = r'''set -e
PYX=Vendor/Python/Python.xcframework
source "$PROJECT_DIR/$PYX/build/utils.sh"
install_stdlib "$PYX"
V=$(ls -1 "$CODESIGNING_FOLDER_PATH/python/lib" | grep -E "^python3\.[0-9]+$")
L="$CODESIGNING_FOLDER_PATH/python/lib/$V"
# not needed to run yt-dlp: the standard library's tests, IDLE, Tk, and the interpreter's own test modules
rm -rf "$L/test" "$L/idlelib" "$L/tkinter" "$L/ensurepip" "$L/turtledemo" "$L/pydoc_data" "$L/lib2to3"
rm -f "$L"/lib-dynload/_test*.so "$L"/lib-dynload/_xx*.so "$L"/lib-dynload/xx*.so "$L"/lib-dynload/_ctypes_test*.so
process_dylibs "$PYX" "python/lib/$V/lib-dynload"
process_dylibs "$PYX" app_packages
'''
# as it must be written inside a .pbxproj string
PY_SCRIPT = PY_SCRIPT_SOURCE.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

PROJECT, MAIN, PRODUCTS, LOCALPKG, CL_PROJECT = (oid(x) for x in ("project", "main", "products", "localpkg", "cl-project"))

o = []   # object sections
def section(name, body):
    o.append(f"/* Begin {name} section */\n{body}/* End {name} section */\n")

buildfiles, filerefs, groups, targets_txt, phases, cfglists, cfgs, pdeps, syncgroups = ([] for _ in range(9))

# The share extension that offers "Add to Musicam" in the iPhone share sheet (embedded in the iOS app).
EXT_NAME, EXT_DIR = "MusicamShare-iOS", "App-iOS-Share"
X = {k: oid("share-" + k) for k in ("id", "product", "sg", "cl", "src", "fw", "res", "debug", "release", "proxy", "dep", "embed", "embed-bf")}

for t in TARGETS:
    n = t["name"]
    t.update(id=oid(n), product=oid(n + "-product"), sg=oid(n + "-sg"), cl=oid(n + "-cl"),
             src=oid(n + "-src"), fw=oid(n + "-fw"), res=oid(n + "-res"),
             cfg={"Debug": oid(n + "-debug"), "Release": oid(n + "-release")})
    filerefs.append(f'\t\t{t["product"]} /* Musicam.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Musicam.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n')
    syncgroups.append(f'\t\t{t["sg"]} /* {t["dir"]} */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = {q(t["dir"])};\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
    is_ios = n == "Musicam-iOS"
    embed_txt = f'\t\t\t\t{X["embed"]} /* Embed Foundation Extensions */,\n' if is_ios else ""
    dep_txt = f'\t\t\t\t{X["dep"]} /* PBXTargetDependency */,\n' if is_ios else ""
    deps, fwfiles = [], []
    for p in PACKAGE_PRODUCTS:
        pd, bf = oid(f"{n}-pd-{p}"), oid(f"{n}-bf-{p}")
        pdeps.append(f'\t\t{pd} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = {p};\n\t\t}};\n')
        buildfiles.append(f'\t\t{bf} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {pd} /* {p} */; }};\n')
        deps.append(f"\t\t\t\t{pd} /* {p} */,\n"); fwfiles.append(f"\t\t\t\t{bf} /* {p} in Frameworks */,\n")
    phases.append(f'\t\t{t["src"]} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
    if is_ios:
        buildfiles.append(f'\t\t{PY["xcfw-fw"]} /* Python.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {PY["xcfw"]} /* Python.xcframework */; }};\n')
        fwfiles.append(f'\t\t\t\t{PY["xcfw-fw"]} /* Python.xcframework in Frameworks */,\n')
        buildfiles.append(f'\t\t{PY["xcfw-embed"]} /* Python.xcframework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {PY["xcfw"]} /* Python.xcframework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};\n')
        buildfiles.append(f'\t\t{PY["app-bf"]} /* app in Resources */ = {{isa = PBXBuildFile; fileRef = {PY["app"]} /* app */; }};\n')
        buildfiles.append(f'\t\t{PY["pkgs-bf"]} /* app_packages in Resources */ = {{isa = PBXBuildFile; fileRef = {PY["pkgs"]} /* app_packages */; }};\n')
    phases.append(f'\t\t{t["fw"]} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{"".join(fwfiles)}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
    is_mac = n == "Musicam-macOS"
    helpers_id = oid(n + "-helpers")
    if is_mac:
        phases.append(f'\t\t{helpers_id} /* Embed Merajfy helpers */ = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputFileListPaths = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);\n\t\t\tname = "Embed Merajfy helpers";\n\t\t\toutputFileListPaths = (\n\t\t\t);\n\t\t\toutputPaths = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/bash;\n\t\t\tshellScript = "\\"$SRCROOT/scripts/embed_helpers.sh\\"\\n";\n\t\t}};\n')
    helpers_txt = f'\t\t\t\t{helpers_id} /* Embed Merajfy helpers */,\n' if is_mac else ""
    resfiles = f'\t\t\t\t{PY["app-bf"]} /* app in Resources */,\n\t\t\t\t{PY["pkgs-bf"]} /* app_packages in Resources */,\n' if is_ios else ""
    pyscript_txt = pyembed_txt = ""
    if is_ios:
        phases.append(f'\t\t{PY["script"]} /* Process Python libraries */ = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputFileListPaths = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);\n\t\t\tname = "Process Python libraries";\n\t\t\toutputFileListPaths = (\n\t\t\t);\n\t\t\toutputPaths = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/sh;\n\t\t\tshellScript = "{PY_SCRIPT}";\n\t\t\tshowEnvVarsInLog = 0;\n\t\t}};\n')
        phases.append(f'\t\t{PY["embed"]} /* Embed Frameworks */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = "";\n\t\t\tdstSubfolderSpec = 10;\n\t\t\tfiles = (\n\t\t\t\t{PY["xcfw-embed"]} /* Python.xcframework in Embed Frameworks */,\n\t\t\t);\n\t\t\tname = "Embed Frameworks";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
        pyscript_txt = f'\t\t\t\t{PY["script"]} /* Process Python libraries */,\n'
        pyembed_txt = f'\t\t\t\t{PY["embed"]} /* Embed Frameworks */,\n'
    phases.append(f'\t\t{t["res"]} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{resfiles}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
    targets_txt.append(
        f'\t\t{t["id"]} /* {n} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {t["cl"]} /* Build configuration list for PBXNativeTarget "{n}" */;\n'
        f'\t\t\tbuildPhases = (\n\t\t\t\t{t["src"]} /* Sources */,\n\t\t\t\t{t["fw"]} /* Frameworks */,\n\t\t\t\t{t["res"]} /* Resources */,\n{helpers_txt}{pyscript_txt}{pyembed_txt}{embed_txt}\t\t\t);\n'
        f'\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n{dep_txt}\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{t["sg"]} /* {t["dir"]} */,\n\t\t\t);\n'
        f'\t\t\tname = {q(n)};\n\t\t\tpackageProductDependencies = (\n{"".join(deps)}\t\t\t);\n\t\t\tproductName = Musicam;\n'
        f'\t\t\tproductReference = {t["product"]} /* Musicam.app */;\n\t\t\tproductType = "com.apple.product-type.application";\n\t\t}};\n')
    for c in ("Debug", "Release"):
        per = dict(t["settings"])
        if c == "Debug":
            # Debug builds get their own identity (and data folder) so testing never touches the real library.
            per["PRODUCT_BUNDLE_IDENTIFIER"] = BUNDLE_ID + ".debug"
            per["INFOPLIST_KEY_CFBundleDisplayName"] = "Musicam"
        cfgs.append(f'\t\t{t["cfg"][c]} /* {c} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(per, chr(9)*4)}\n\t\t\t}};\n\t\t\tname = {c};\n\t\t}};\n')
    cfglists.append(f'\t\t{t["cl"]} /* Build configuration list for PBXNativeTarget "{n}" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{t["cfg"]["Debug"]} /* Debug */,\n\t\t\t\t{t["cfg"]["Release"]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n')

ext_settings = {
    "CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": "9VF66R9227", "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_FILE": "Config/iOS-Share-Info.plist",
    "INFOPLIST_KEY_CFBundleDisplayName": "Musicam", "INFOPLIST_KEY_NSHumanReadableCopyright": "Copyright 2026 Meraj Mirbazel",
    "IPHONEOS_DEPLOYMENT_TARGET": "18.0", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
    "MARKETING_VERSION": "0.13.0", "PRODUCT_NAME": "MusicamShare", "SDKROOT": "iphoneos", "SKIP_INSTALL": "YES",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SWIFT_VERSION": "6.0", "TARGETED_DEVICE_FAMILY": "1,2",
}
for key, name, kind, path in PY_FILES:
    filerefs.append(f'\t\t{PY[key]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = "<group>"; }};\n')
filerefs.append(f'\t\t{X["product"]} /* MusicamShare.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = MusicamShare.appex; sourceTree = BUILT_PRODUCTS_DIR; }};\n')
syncgroups.append(f'\t\t{X["sg"]} /* {EXT_DIR} */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = {q(EXT_DIR)};\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
for key, label, isa in (("src", "Sources", "PBXSourcesBuildPhase"), ("fw", "Frameworks", "PBXFrameworksBuildPhase"), ("res", "Resources", "PBXResourcesBuildPhase")):
    phases.append(f'\t\t{X[key]} /* {label} */ = {{\n\t\t\tisa = {isa};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
targets_txt.append(
    f'\t\t{X["id"]} /* {EXT_NAME} */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {X["cl"]} /* Build configuration list for PBXNativeTarget "{EXT_NAME}" */;\n'
    f'\t\t\tbuildPhases = (\n\t\t\t\t{X["src"]} /* Sources */,\n\t\t\t\t{X["fw"]} /* Frameworks */,\n\t\t\t\t{X["res"]} /* Resources */,\n\t\t\t);\n'
    f'\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{X["sg"]} /* {EXT_DIR} */,\n\t\t\t);\n'
    f'\t\t\tname = {EXT_NAME};\n\t\t\tpackageProductDependencies = (\n\t\t\t);\n\t\t\tproductName = MusicamShare;\n'
    f'\t\t\tproductReference = {X["product"]} /* MusicamShare.appex */;\n\t\t\tproductType = "com.apple.product-type.app-extension";\n\t\t}};\n')
for c in ("Debug", "Release"):
    per = dict(ext_settings)
    per["PRODUCT_BUNDLE_IDENTIFIER"] = BUNDLE_ID + (".debug.share" if c == "Debug" else ".share")
    cfgs.append(f'\t\t{X[c.lower()]} /* {c} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(per, chr(9)*4)}\n\t\t\t}};\n\t\t\tname = {c};\n\t\t}};\n')
cfglists.append(f'\t\t{X["cl"]} /* Build configuration list for PBXNativeTarget "{EXT_NAME}" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{X["debug"]} /* Debug */,\n\t\t\t\t{X["release"]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n')
buildfiles.append(f'\t\t{X["embed-bf"]} /* MusicamShare.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {X["product"]} /* MusicamShare.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n')
phases.append(f'\t\t{X["embed"]} /* Embed Foundation Extensions */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = "";\n\t\t\tdstSubfolderSpec = 13;\n\t\t\tfiles = (\n\t\t\t\t{X["embed-bf"]} /* MusicamShare.appex in Embed Foundation Extensions */,\n\t\t\t);\n\t\t\tname = "Embed Foundation Extensions";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')

pcfg = {c: oid("project-" + c) for c in ("Debug", "Release")}
for c in ("Debug", "Release"):
    cfgs.append(f'\t\t{pcfg[c]} /* {c} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(project_cfg[c], chr(9)*4)}\n\t\t\t}};\n\t\t\tname = {c};\n\t\t}};\n')
cfglists.append(f'\t\t{CL_PROJECT} /* Build configuration list for PBXProject "Musicam" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{pcfg["Debug"]} /* Debug */,\n\t\t\t\t{pcfg["Release"]} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n')

groups.append(f'\t\t{MAIN} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "".join(f'\t\t\t\t{t["sg"]} /* {t["dir"]} */,\n' for t in TARGETS) + f'\t\t\t\t{X["sg"]} /* {EXT_DIR} */,\n' + "".join(f'\t\t\t\t{PY[k]} /* {nm} */,\n' for k, nm, _, _ in PY_FILES) + f'\t\t\t\t{PRODUCTS} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
groups.append(f'\t\t{PRODUCTS} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "".join(f'\t\t\t\t{t["product"]} /* Musicam.app */,\n' for t in TARGETS) + f'\t\t\t\t{X["product"]} /* MusicamShare.appex */,\n' + '\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t};\n')

project_txt = (
    f'\t\t{PROJECT} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2700;\n\t\t\t\tLastUpgradeCheck = 2700;\n\t\t\t}};\n'
    f'\t\t\tbuildConfigurationList = {CL_PROJECT} /* Build configuration list for PBXProject "Musicam" */;\n\t\t\tcompatibilityVersion = "Xcode 14.0";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n'
    f'\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tfa,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {MAIN};\n\t\t\tminimizedProjectReferenceProxies = 1;\n'
    f'\t\t\tpackageReferences = (\n\t\t\t\t{LOCALPKG} /* XCLocalSwiftPackageReference "MusicamKit" */,\n\t\t\t);\n\t\t\tproductRefGroup = {PRODUCTS} /* Products */;\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n'
    f'\t\t\ttargets = (\n' + "".join(f'\t\t\t\t{t["id"]} /* {t["name"]} */,\n' for t in TARGETS) + f'\t\t\t\t{X["id"]} /* {EXT_NAME} */,\n' + '\t\t\t);\n\t\t};\n')

section("PBXBuildFile", "".join(buildfiles))
section("PBXContainerItemProxy", f'\t\t{X["proxy"]} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {PROJECT} /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {X["id"]};\n\t\t\tremoteInfo = {EXT_NAME};\n\t\t}};\n')
section("PBXTargetDependency", f'\t\t{X["dep"]} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = {X["id"]} /* {EXT_NAME} */;\n\t\t\ttargetProxy = {X["proxy"]} /* PBXContainerItemProxy */;\n\t\t}};\n')
section("PBXCopyFilesBuildPhase", "".join(p for p in phases if "PBXCopyFilesBuildPhase" in p))
section("PBXFileReference", "".join(filerefs))
section("PBXFileSystemSynchronizedRootGroup", "".join(syncgroups))
section("PBXFrameworksBuildPhase", "".join(p for p in phases if "PBXFrameworksBuildPhase" in p))
section("PBXGroup", "".join(groups))
section("PBXNativeTarget", "".join(targets_txt))
section("PBXProject", project_txt)
section("PBXResourcesBuildPhase", "".join(p for p in phases if "PBXResourcesBuildPhase" in p))
section("PBXShellScriptBuildPhase", "".join(p for p in phases if "PBXShellScriptBuildPhase" in p))
section("PBXSourcesBuildPhase", "".join(p for p in phases if "PBXSourcesBuildPhase" in p))
section("XBuildConfiguration".replace("XB", "XCB"), "".join(cfgs))
section("XCConfigurationList", "".join(cfglists))
section("XCLocalSwiftPackageReference", f'\t\t{LOCALPKG} /* XCLocalSwiftPackageReference "MusicamKit" */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = MusicamKit;\n\t\t}};\n')
section("XCSwiftPackageProductDependency", "".join(pdeps))

pbx = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\n" + "\n".join(o) + f"\t}};\n\trootObject = {PROJECT} /* Project object */;\n}}\n"

os.makedirs(PROJ, exist_ok=True)
open(os.path.join(PROJ, "project.pbxproj"), "w").write(pbx)

# Shared schemes, so `xcodebuild -scheme Musicam-macOS` works without opening Xcode first.
sd = os.path.join(PROJ, "xcshareddata", "xcschemes")
os.makedirs(sd, exist_ok=True)
for t in TARGETS:
    ref = f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{t["id"]}" BuildableName = "Musicam.app" BlueprintName = "{t["name"]}" ReferencedContainer = "container:Musicam.xcodeproj"></BuildableReference>'
    open(os.path.join(sd, t["name"] + ".xcscheme"), "w").write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
''')
print("wrote", PROJ)
