#!/usr/bin/env python3
"""Package ComicConverter.app into dist/ComicConverter-<version>-arm64.dmg and verify the image."""
from pathlib import Path
import tempfile,subprocess,plistlib,hashlib
from toolchain import ROOT,VERSION
out=ROOT/'dist'; out.mkdir(exist_ok=True)
dmg=out/f'ComicConverter-{VERSION}-arm64.dmg'
if dmg.exists(): raise SystemExit('DMG already exists; move it aside before rebuilding.')
with tempfile.TemporaryDirectory(prefix='comic-dmg-') as tmp:
    stage=Path(tmp)
    subprocess.run(['ditto',str(ROOT/'ComicConverter.app'),str(stage/'Comic Converter.app')],check=True)
    (stage/'Applications').symlink_to('/Applications',target_is_directory=True)
    (stage/'使用说明.txt').write_text(f'''漫画格式转换 {VERSION}

安装：将「Comic Converter.app」拖入 Applications（应用程序），再从应用程序打开。
从旧版升级：先删除“应用程序”中的「漫画格式转换.app」，再拖入新版；若曾创建 comicconv 命令行链接，请按下面的命令重新执行 ln -sf 指向新路径。
适用于 Apple Silicon（M 系列）Mac，macOS 13 或更新版本。
未使用付费 Developer ID 签名，未经 Apple 公证；若首次启动被拦截，在尝试打开后前往「系统设置 → 隐私与安全性 → 仍要打开」。

读取：CBZ/ZIP、CBR/RAR、CB7/7Z、CBT/TAR、PDF、EPUB、MOBI、AZW3、AZW、PRC、图片文件夹
输出：CBZ、CBR（需安装 rar）、CB7、CBT、PDF、EPUB（固定版式）、MOBI、AZW3（需安装 Calibre）、图片文件夹

命令行：应用内附带 comicconv，可在终端执行
  sudo ln -sf "/Applications/Comic Converter.app/Contents/MacOS/comicconv" /usr/local/bin/comicconv
  comicconv -t cbz ~/Comics/
  comicconv -t cbz --name "{{标题}} 第{{序号}}卷" ~/Comics/   # 转换时批量命名
  comicconv --inspect 某本书.mobi   # 转换失败时打印结构摘要，方便反馈

不支持带 DRM 的文件与 KFX 格式。源文件不会被修改，同名输出自动加序号，不覆盖已有文件。
''')
    (stage/'Read Me.txt').write_text(f'''Comic Converter {VERSION}

Installation: Drag "Comic Converter.app" into Applications, then open it from Applications.
Upgrading: first delete the old "漫画格式转换.app" from Applications, then drag in the new version. If you created the comicconv command-line link, run the ln -sf command below again so it points to the new path.
Requires an Apple Silicon (M-series) Mac running macOS 13 or later.
The app has no paid Developer ID signature or Apple notarization. If the first launch is blocked, try opening it, then go to System Settings → Privacy & Security → Open Anyway.

Read: CBZ/ZIP, CBR/RAR, CB7/7Z, CBT/TAR, PDF, EPUB, MOBI, AZW3, AZW, PRC, image folders
Write: CBZ, CBR (requires rar), CB7, CBT, PDF, EPUB (fixed layout), MOBI, AZW3 (requires Calibre), image folders

Command line: comicconv is bundled with the app. Run in Terminal:
  sudo ln -sf "/Applications/Comic Converter.app/Contents/MacOS/comicconv" /usr/local/bin/comicconv
  comicconv -t cbz ~/Comics/
  comicconv -t cbz --name "{{title}} Vol. {{n}}" ~/Comics/   # Rename while converting
  comicconv --inspect book.mobi   # Print a structural summary to report a conversion failure

DRM-protected files and KFX are not supported. Source files are never modified. Existing output is preserved; a number is appended if the name is taken.
''')
    subprocess.run(['hdiutil','create','-volname','Comic Converter','-srcfolder',str(stage),'-format','UDZO','-o',str(dmg)],check=True)
subprocess.run(['hdiutil','verify',str(dmg)],check=True)
result=subprocess.run(['hdiutil','attach','-readonly','-nobrowse','-plist',str(dmg)],check=True,capture_output=True)
mounts=[e['mount-point'] for e in plistlib.loads(result.stdout)['system-entities'] if 'mount-point' in e]
try:
    for m in mounts:
        app=Path(m)/'Comic Converter.app'
        assert (app/'Contents/MacOS/comicconv').is_file()
        assert (Path(m)/'Applications').is_symlink()
        subprocess.run(['codesign','--verify','--strict','--verbose=2',str(app)],check=True)
        v=subprocess.run([str(app/'Contents/MacOS/comicconv'),'--version'],capture_output=True,text=True,check=True).stdout.strip()
        assert v==f'comicconv {VERSION}',v
finally:
    for m in mounts: subprocess.run(['hdiutil','detach',m],check=True)
sha=hashlib.sha256(dmg.read_bytes()).hexdigest()
(dmg.with_suffix('.dmg.sha256')).write_text(sha+'  '+dmg.name+'\n')
print('READY',dmg,'bytes',dmg.stat().st_size,'sha256',sha)
