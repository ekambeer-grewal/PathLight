#!/usr/bin/env python3
"""Rebuild the checked-in Xcode project using Python's standard library only."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

def quote(value):
    return json.dumps(value)

def obj(name, isa, body):
    key = uid(name)
    objects[key] = '{ isa = ' + isa + '; ' + body + ' };'
    return key

def ids(values):
    return '(' + ', '.join(values) + (',' if values else '') + ')'

sources = sorted((ROOT / 'PathLight').glob('*.swift'))
tests = sorted((ROOT / 'Tests').glob('*.swift'))
source_refs, source_builds, test_refs, test_builds = [], [], [], []
for paths, refs, builds in [(sources, source_refs, source_builds), (tests, test_refs, test_builds)]:
    for path in paths:
        ref = obj(str(path.relative_to(ROOT)), 'PBXFileReference',
                  f'lastKnownFileType = sourcecode.swift; path = {quote(path.name)}; sourceTree = "<group>";')
        refs.append(ref)
        builds.append(obj('build-' + str(path.relative_to(ROOT)), 'PBXBuildFile', f'fileRef = {ref};'))

info = obj('info', 'PBXFileReference', 'lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
beep = obj('beep', 'PBXFileReference', 'lastKnownFileType = audio.wav; path = beep.wav; sourceTree = "<group>";')
beep_build = obj('beep-build', 'PBXBuildFile', f'fileRef = {beep};')
app = obj('app-product', 'PBXFileReference', 'explicitFileType = wrapper.application; includeInIndex = 0; path = PathLight.app; sourceTree = BUILT_PRODUCTS_DIR;')
test = obj('test-product', 'PBXFileReference', 'explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = PathLightTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
app_group = obj('app-group', 'PBXGroup', f'children = {ids(source_refs + [info, beep])}; path = PathLight; sourceTree = "<group>";')
test_group = obj('test-group', 'PBXGroup', f'children = {ids(test_refs)}; path = Tests; sourceTree = "<group>";')
products = obj('products', 'PBXGroup', f'children = {ids([app,test])}; name = Products; sourceTree = "<group>";')
main = obj('main', 'PBXGroup', f'children = {ids([app_group,test_group,products])}; sourceTree = "<group>";')

def phase(name, kind, files):
    return obj(name, kind, f'buildActionMask = 2147483647; files = {ids(files)}; runOnlyForDeploymentPostprocessing = 0;')

app_phases = [phase('app-sources','PBXSourcesBuildPhase',source_builds), phase('app-frameworks','PBXFrameworksBuildPhase',[]), phase('app-resources','PBXResourcesBuildPhase',[beep_build])]
test_phases = [phase('test-sources','PBXSourcesBuildPhase',test_builds), phase('test-frameworks','PBXFrameworksBuildPhase',[]), phase('test-resources','PBXResourcesBuildPhase',[])]

def config_list(prefix, common):
    configs = []
    for name in ['Debug', 'Release']:
        settings = dict(common)
        if prefix == 'project':
            settings.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if name == 'Debug' else '-O',
                             'DEBUG_INFORMATION_FORMAT': 'dwarf' if name == 'Debug' else 'dwarf-with-dsym',
                             'ENABLE_TESTABILITY': 'YES' if name == 'Debug' else 'NO'})
            if name == 'Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
        content = ' '.join(f'{key} = {quote(value)};' for key, value in settings.items())
        configs.append(obj(prefix + name, 'XCBuildConfiguration', f'buildSettings = {{ {content} }}; name = {name};'))
    return obj(prefix+'-configs','XCConfigurationList',f'buildConfigurations = {ids(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

project_configs = config_list('project', {'ALWAYS_SEARCH_USER_PATHS':'NO','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'minimal','GCC_C_LANGUAGE_STANDARD':'gnu17'})
common = {'CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'','TARGETED_DEVICE_FAMILY':'1','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','SWIFT_EMIT_LOC_STRINGS':'YES'}
app_configs = config_list('app', {**common,'PRODUCT_BUNDLE_IDENTIFIER':'com.healthhack.PathLight','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'PathLight/Info.plist','GENERATE_INFOPLIST_FILE':'NO','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks'})
test_configs = config_list('tests', {**common,'PRODUCT_BUNDLE_IDENTIFIER':'com.healthhack.PathLightTests','PRODUCT_NAME':'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/PathLight.app/PathLight','BUNDLE_LOADER':'$(TEST_HOST)','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
proxy = obj('proxy','PBXContainerItemProxy',f'containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("app-target")}; remoteInfo = PathLight;')
dependency = obj('dependency','PBXTargetDependency',f'target = {uid("app-target")}; targetProxy = {proxy};')
app_target = obj('app-target','PBXNativeTarget',f'buildConfigurationList = {app_configs}; buildPhases = {ids(app_phases)}; buildRules = (); dependencies = (); name = PathLight; productName = PathLight; productReference = {app}; productType = "com.apple.product-type.application";')
test_target = obj('test-target','PBXNativeTarget',f'buildConfigurationList = {test_configs}; buildPhases = {ids(test_phases)}; buildRules = (); dependencies = {ids([dependency])}; name = PathLightTests; productName = PathLightTests; productReference = {test}; productType = "com.apple.product-type.bundle.unit-test";')
project = obj('project','PBXProject',f'attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {app_target} = {{ CreatedOnToolsVersion = 16.0; }}; {test_target} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {app_target}; }}; }}; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {ids([app_target,test_target])};')
text = '// !$*UTF8*$!\n{\n archiveVersion = 1;\n classes = {};\n objectVersion = 56;\n objects = {\n'
text += '\n'.join(f'  {key} = {value}' for key,value in objects.items())
text += f'\n }};\n rootObject = {project};\n}}\n'
project_dir = ROOT/'PathLight.xcodeproj'
project_dir.mkdir(exist_ok=True)
(project_dir/'project.pbxproj').write_text(text)
scheme_dir = project_dir/'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True,exist_ok=True)
def reference(target, buildable, name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{buildable}" BlueprintName="{name}" ReferencedContainer="container:PathLight.xcodeproj"/>'
app_ref=reference(app_target,'PathLight.app','PathLight')
test_ref=reference(test_target,'PathLightTests.xctest','PathLightTests')
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(scheme_dir/'PathLight.xcscheme').write_text(scheme)
print('Rebuilt PathLight.xcodeproj and shared scheme.')
