#!/usr/bin/env python3
"""Regenerate Assets/AppIcon.png and Assets/AppIcon.icns from MakeIcon.swift."""
from pathlib import Path
import subprocess,tempfile,sys
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from toolchain import ROOT,sdk_path
A=ROOT/'Assets'
with tempfile.TemporaryDirectory() as tmp:
    exe=Path(tmp)/'makeicon'
    subprocess.run(['xcrun','swiftc','-sdk',sdk_path(),'-module-cache-path',str(ROOT/'ModuleCache'),str(A/'MakeIcon.swift'),'-o',str(exe)],check=True)
    subprocess.run([str(exe),str(A/'AppIcon.png')],check=True)
    iconset=Path(tmp)/'AppIcon.iconset'; iconset.mkdir()
    for s in [16,32,128,256,512]:
        for scale in (1,2):
            name=f'icon_{s}x{s}'+('@2x' if scale==2 else '')+'.png'
            subprocess.run(['sips','-z',str(s*scale),str(s*scale),str(A/'AppIcon.png'),'--out',str(iconset/name)],check=True,capture_output=True)
    subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(A/'AppIcon.icns')],check=True)
print(A/'AppIcon.icns')
