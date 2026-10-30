"""Shared swiftc invocation for build.py, test.py and package.py."""
from pathlib import Path
import os,re,subprocess
ROOT=Path(__file__).resolve().parent
VERSION='1.1.0'
BUILD='2'
CORE=sorted((ROOT/'Sources/Core').glob('*.swift'))

def sdk_path():
    """Command Line Tools ship no SwiftUI macro plugin, but macOS 27+ SDKs implement @State as a macro.
    Without Xcode, fall back to the newest installed pre-27 SDK. COMICCONV_SDK overrides the choice."""
    if os.environ.get('COMICCONV_SDK'): return os.environ['COMICCONV_SDK']
    dev=Path(subprocess.run(['xcode-select','-p'],capture_output=True,text=True,check=True).stdout.strip())
    default=Path(subprocess.run(['xcrun','--show-sdk-path'],capture_output=True,text=True,check=True).stdout.strip())
    plugins=dev/'usr/lib/swift/host/plugins'
    if 'CommandLineTools' not in str(dev) or any(plugins.glob('*SwiftUIMacros*')): return str(default)
    versions=[]
    for sdk in (dev/'SDKs').glob('MacOSX*.*.sdk'):
        m=re.fullmatch(r'MacOSX(\d+)\.(\d+)\.sdk',sdk.name)
        if m and int(m[1])<27: versions.append(((int(m[1]),int(m[2])),sdk))
    return str(max(versions)[1]) if versions else str(default)

def version_source():
    out=ROOT/'.build/Version.swift'; out.parent.mkdir(exist_ok=True)
    text=f'enum AppVersion {{ static let string = "{VERSION}" }}\n'
    if not out.exists() or out.read_text()!=text: out.write_text(text)
    return out

def swiftc(sources,output,*flags):
    Path(output).parent.mkdir(parents=True,exist_ok=True)
    subprocess.run(['xcrun','swiftc','-sdk',sdk_path(),'-parse-as-library','-target','arm64-apple-macos13.0','-module-cache-path',str(ROOT/'ModuleCache'),*flags,*map(str,[*CORE,version_source(),*sources]),'-o',str(output)],check=True)
