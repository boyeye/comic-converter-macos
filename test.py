#!/usr/bin/env python3
"""End-to-end tests: every format round-trips page order, colors and (where promised) exact bytes.
Calibre, when installed, cross-checks the MOBI/EPUB/AZW3 output and supplies third-party MOBI/AZW3 input."""
from pathlib import Path
import json,shutil,subprocess,sys,tempfile,zipfile
from toolchain import ROOT,swiftc
B=ROOT/'.build'
CLI=B/'comicconv'; FIX=B/'fixtures'
swiftc(sorted((ROOT/'Sources/CLI').glob('*.swift')),CLI)
swiftc([ROOT/'Tests/Fixtures.swift'],FIX)
CALIBRE=Path('/Applications/calibre.app/Contents/MacOS')
HAS_CALIBRE=(CALIBRE/'ebook-convert').exists()
results=[]

def check(name,ok,detail=''):
    results.append({'test':name,'passed':bool(ok),'detail':detail})
    print(('PASS ' if ok else 'FAIL ')+name+(f'  ({detail})' if detail and not ok else ''))

def conv(fmt,*inputs,out,extra=()):
    return subprocess.run([str(CLI),'-t',fmt,'-o',str(out),*extra,*map(str,inputs)],capture_output=True,text=True)

def colors(paths):
    if not paths: return []
    out=subprocess.run([str(FIX),'color',*map(str,paths)],capture_output=True,text=True,check=True).stdout.split('\n')
    return [tuple(map(int,l.split())) for l in out if l]

def cbz_pages(cbz,dest):
    with zipfile.ZipFile(cbz) as z:
        assert z.testzip() is None
        z.extractall(dest)
        names=[n for n in z.namelist() if n!='ComicInfo.xml']
    return [dest/n for n in sorted(names)], (dest/'ComicInfo.xml').read_text() if (dest/'ComicInfo.xml').exists() else ''

def same_colors(got,want,tol=14):
    return len(got)==len(want) and all(max(abs(a-b) for a,b in zip(g[:3],w[:3]))<=tol and g[3:]==w[3:] for g,w in zip(got,want))

with tempfile.TemporaryDirectory(prefix='comicconv-test-') as tmp:
    T=Path(tmp); src=T/'src'
    subprocess.run([str(FIX),'pages',str(src),'12'],check=True)
    order=sorted(src.iterdir(),key=lambda p:int(p.stem[4:]))
    want=colors(order)
    jpeg_idx=[i for i,p in enumerate(order) if p.suffix=='.jpg']
    png_idx=[i for i,p in enumerate(order) if p.suffix=='.png']

    def roundtrip(label,source,lossless_png=True,tol=14,expect=want,jpeg_exact=True):
        back=T/f'back-{label}'; back.mkdir()
        r=conv('cbz',source,out=back)
        cbzs=list(back.glob('*.cbz'))
        if r.returncode or len(cbzs)!=1: return check(f'{label} → cbz',False,r.stdout+r.stderr)
        pages,info=cbz_pages(cbzs[0],back/'x')
        got=colors(pages)
        check(f'{label}: 页数与页序',same_colors(got,expect,tol),f'{len(got)} pages; {got[:3]} vs {expect[:3]}')
        if jpeg_exact:
            check(f'{label}: JPEG 无损',all(pages[i].read_bytes()==order[i].read_bytes() for i in jpeg_idx))
        if lossless_png:
            check(f'{label}: PNG 无损',all(pages[i].read_bytes()==order[i].read_bytes() for i in png_idx))
        return pages,info

    # 1. Image folder → every format → back to CBZ.
    outs=T/'outs'; outs.mkdir()
    formats=['cbz','cb7','cbt','pdf','epub','mobi','folder']+(['azw3'] if HAS_CALIBRE else [])
    for fmt in formats:
        r=conv(fmt,src,out=outs)
        check(f'文件夹 → {fmt}',r.returncode==0,r.stdout+r.stderr)
    for fmt in ['cbz','cb7','cbt','folder','epub','mobi']:
        roundtrip(fmt,outs/('src' if fmt=='folder' else f'src.{fmt}'))
    roundtrip('pdf',outs/'src.pdf',lossless_png=False)
    if HAS_CALIBRE: roundtrip('azw3(Calibre 生成)',outs/'src.azw3',lossless_png=False,tol=20,jpeg_exact=False)

    # 2. Container details.
    with zipfile.ZipFile(outs/'src.epub') as z:
        first=z.infolist()[0]
        check('EPUB: mimetype 位于首位且未压缩',first.filename=='mimetype' and first.compress_type==zipfile.ZIP_STORED and z.read('mimetype')==b'application/epub+zip')
        opf=z.read('OEBPS/content.opf').decode()
        check('EPUB: 固定版式元数据','pre-paginated' in opf and 'book-type' in opf)
    filters=subprocess.run([str(FIX),'inspect',str(outs/'src.pdf')],capture_output=True,text=True,check=True).stdout.split()
    check('PDF: JPEG 页以 DCTDecode 原样嵌入',all(filters[i]=='DCTDecode' for i in jpeg_idx),str(filters))
    tar=subprocess.run(['/usr/bin/tar','-tf',str(outs/'src.cb7')],capture_output=True,text=True)
    check('CB7: 7z 包可列出 12 页 + ComicInfo',tar.returncode==0 and len(tar.stdout.split())==13,tar.stdout)

    # 3. Calibre cross-validation.
    if HAS_CALIBRE:
        for fmt in ['mobi','epub','azw3']:
            m=subprocess.run([str(CALIBRE/'ebook-meta'),str(outs/f'src.{fmt}')],capture_output=True,text=True)
            check(f'Calibre 识别本工具生成的 {fmt.upper()}',m.returncode==0 and 'src' in m.stdout,m.stdout[-300:])
        r=subprocess.run([str(CALIBRE/'ebook-convert'),str(outs/'src.mobi'),str(T/'calibre-from-mobi.epub')],capture_output=True,text=True)
        check('Calibre 可完整转换本工具生成的 MOBI',r.returncode==0,r.stdout[-300:])
        cal=T/'calibre'; cal.mkdir()
        for label,args in [('MOBI6',['--mobi-file-type','old']),('MOBI6+KF8 联合',['--mobi-file-type','both']),('AZW3',[])]:
            ext='azw3' if label=='AZW3' else 'mobi'
            dest=cal/f"{label.split()[0].replace('+','_')}.{ext}"
            r=subprocess.run([str(CALIBRE/'ebook-convert'),str(outs/'src.epub'),str(dest),*args],capture_output=True,text=True)
            if r.returncode: check(f'Calibre 生成 {label}',False,r.stdout[-300:]); continue
            roundtrip(f'Calibre {label} 输入',dest,lossless_png=False,tol=20,jpeg_exact=False)

    # 4. Reading direction metadata survives conversions.
    rtl=T/'rtl'; rtl.mkdir()
    conv('epub',src,out=rtl,extra=['--rtl'])
    with zipfile.ZipFile(rtl/'src.epub') as z: check('--rtl 写入 EPUB 翻页方向','page-progression-direction="rtl"' in z.read('OEBPS/content.opf').decode())
    conv('mobi',rtl/'src.epub',out=rtl)
    conv('cbz',rtl/'src.mobi',out=rtl)
    with zipfile.ZipFile(rtl/'src.cbz') as z: check('阅读方向经 EPUB→MOBI→CBZ 保留','YesAndRightToLeft' in z.read('ComicInfo.xml').decode())

    # 5. Vector PDF pages are rendered at the requested DPI.
    vec=T/'vector'; vec.mkdir()
    subprocess.run([str(FIX),'textpdf',str(vec/'v.pdf')],check=True)
    r=conv('cbz',vec/'v.pdf',out=vec,extra=['--dpi','150'])
    pages,_=cbz_pages(vec/'v.cbz',vec/'x') if r.returncode==0 else ([],'')
    c=colors(pages)
    check('矢量 PDF 按 DPI 渲染',len(c)==1 and c[0][3]==round(595*150/72) and '重新渲染' in r.stdout,r.stdout+str(c))

    # 6. Safety and error handling.
    again=conv('cbz',src,out=outs)
    check('同名输出不覆盖，自动编号',again.returncode==0 and (outs/'src (1).cbz').exists() and (outs/'src.cbz').exists())
    drm=bytearray((outs/'src.mobi').read_bytes())
    rec0=int.from_bytes(drm[78:82],'big'); drm[rec0+12:rec0+14]=(2).to_bytes(2,'big')
    (T/'drm.mobi').write_bytes(drm)
    r=conv('cbz',T/'drm.mobi',out=T)
    check('DRM 加密 MOBI 被识别并拒绝',r.returncode==1 and 'DRM' in r.stdout,r.stdout)
    (T/'book.kfx').write_bytes(b'CONT\x02\x00'+b'\0'*100)
    r=conv('cbz',T/'book.kfx',out=T)
    check('KFX 给出明确提示',r.returncode==1 and 'KFX' in r.stdout,r.stdout)
    r=conv('cbr',src,out=T)
    check('不支持写出 CBR（RAR 为专有格式）',r.returncode==2)
    evil=T/'evil'; evil.mkdir()
    with zipfile.ZipFile(evil/'evil.cbz','w') as z:
        z.writestr('../escaped.jpg',order[0].read_bytes()); z.writestr('ok.jpg',order[0].read_bytes())
    conv('cbz',evil/'evil.cbz',out=evil)
    check('压缩包路径穿越被阻止',not any(T.rglob('escaped.jpg')))
    shutil.copy(outs/'src.cbz',T/'renamed.cbr')
    r=conv('epub',T/'renamed.cbr',out=T)
    check('扩展名为 .cbr 的 ZIP 包可读取',r.returncode==0,r.stdout)
    batch=T/'batch'; (batch/'sub').mkdir(parents=True)
    for n in ['a.cbz','sub/b.mobi','sub/c.epub']: shutil.copy(outs/('src.'+n.split('.')[-1]),batch/n)
    r=conv('pdf',batch,out=T/'outs',extra=[])
    check('文件夹批量转换（递归）',r.returncode==0 and '成功 3' in r.stdout,r.stdout)
    src_after=sorted(p.name for p in src.iterdir())
    check('源文件未被改动',src_after==sorted(p.name for p in order))

passed=all(r['passed'] for r in results)
(ROOT/'Tests/results.json').write_text(json.dumps({'passed':passed,'calibre':HAS_CALIBRE,'results':results},ensure_ascii=False,indent=2))
print(f"\n{sum(r['passed'] for r in results)}/{len(results)} passed")
sys.exit(0 if passed else 1)
