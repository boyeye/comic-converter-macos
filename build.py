#!/usr/bin/env python3
"""Build ComicConverter.app (GUI + bundled comicconv CLI) using Command Line Tools."""
from pathlib import Path
import plistlib,subprocess,shutil
from toolchain import ROOT,swiftc,VERSION,BUILD
APP=ROOT/'ComicConverter.app'
shutil.rmtree(APP,ignore_errors=True)
contents=APP/'Contents'; binary=contents/'MacOS'; resources=contents/'Resources'
resources.mkdir(parents=True)
swiftc(sorted((ROOT/'Sources/App').glob('*.swift')),binary/'ComicConverter','-O')
swiftc(sorted((ROOT/'Sources/CLI').glob('*.swift')),binary/'comicconv','-O')
shutil.copy2(ROOT/'Assets/AppIcon.icns',resources/'AppIcon.icns')
comics=['cbz','cbr','cb7','cbt','zip','rar','7z','tar','pdf','epub','mobi','azw3','azw','prc']
info={'CFBundleInfoDictionaryVersion':'6.0','CFBundleExecutable':'ComicConverter','CFBundleIdentifier':'io.github.boyeye.comicconverter',
 'CFBundleName':'ComicConverter','CFBundleDisplayName':'漫画格式转换','CFBundlePackageType':'APPL','CFBundleVersion':BUILD,
 'CFBundleShortVersionString':VERSION,'LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'CFBundleIconFile':'AppIcon.icns',
 'LSApplicationCategoryType':'public.app-category.utilities',
 'CFBundleDocumentTypes':[{'CFBundleTypeName':'漫画与电子书','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','CFBundleTypeExtensions':comics},
                          {'CFBundleTypeName':'图片文件夹','CFBundleTypeRole':'Viewer','LSHandlerRank':'None','LSItemContentTypes':['public.folder']}]}
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--sign','-',str(binary/'comicconv')],check=True)
subprocess.run(['codesign','--force','--sign','-',str(APP)],check=True)
subprocess.run(['codesign','--verify','--strict','--verbose=2',str(APP)],check=True)
print(APP)
