#!/usr/bin/env python3
"""End-to-end tests: every format round-trips page order, colors and (where promised) exact bytes.
Calibre, when installed, cross-checks the MOBI/EPUB/AZW3 output and supplies third-party MOBI/AZW3 input."""
from pathlib import Path
import json,os,shutil,subprocess,sys,tempfile,zipfile
from toolchain import ROOT,swiftc
B=ROOT/'.build'
CLI=B/'comicconv'; FIX=B/'fixtures'
swiftc(sorted((ROOT/'Sources/CLI').glob('*.swift')),CLI)
swiftc([ROOT/'Tests/Fixtures.swift'],FIX)
HARNESS=B/'model-harness'
swiftc([ROOT/'Sources/App/Model.swift',ROOT/'Tests/ModelHarness.swift'],HARNESS)
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


def palm_records(b):
    n=int.from_bytes(b[76:78],'big'); offs=[int.from_bytes(b[78+8*i:82+8*i],'big') for i in range(n)]
    return [bytes(b[offs[i]:(offs[i+1] if i+1<n else len(b))]) for i in range(n)]

def palm_build(header,recs):
    out=bytearray(header[:76])+len(recs).to_bytes(2,'big'); off=78+8*len(recs)+2
    for i,r in enumerate(recs): out+=off.to_bytes(4,'big')+(2*i).to_bytes(4,'big'); off+=len(r)
    return bytes(out)+b'\0\0'+b''.join(recs)

def palmdoc(data):
    out=bytearray(); i=0
    while i<len(data):
        c=data[i]; i+=1
        if 1<=c<=8: out+=data[i:i+c]; i+=c
        elif c<0x80: out.append(c)
        elif c>=0xC0: out+=bytes([0x20,c^0x80])
        else:
            v=((c<<8)|data[i])&0x3FFF; i+=1
            for _ in range((v&7)+3): out.append(out[-(v>>3)])
    return bytes(out)

def trailing(rec,flags):
    end=len(rec); f=flags>>1
    while f:
        if f&1:
            size=0
            for b in rec[max(0,end-4):end]:
                if b&0x80: size=0
                size=(size<<7)|(b&0x7F)
            end-=size
        f>>=1
    if flags&1: end-=(rec[end-1]&3)+1
    return rec[:end]

def with_resc_first(book):
    """Mimic kindlegen/KCC layout: a RESC record sits at the first-resource index, so every image
    reference (recindex / kindle:embed) counts it. Text is rewritten uncompressed with shifted ids."""
    recs=palm_records(book); r0=bytearray(recs[0])
    first=int.from_bytes(r0[108:112],'big'); ntext=int.from_bytes(r0[8:10],'big')
    comp=int.from_bytes(r0[0:2],'big'); hl=int.from_bytes(r0[20:24],'big')
    flags=int.from_bytes(r0[0xF2:0xF4],'big') if hl>=0xE4 else 0
    text=b''.join((palmdoc if comp==2 else bytes)(trailing(recs[i],flags)) for i in range(1,ntext+1))
    import re
    if b'kindle:embed:' in text:
        def b32(n):
            d='0123456789ABCDEFGHIJKLMNOPQRSTUV'; return ''.join(d[(n>>s)&31] for s in (15,10,5,0))
        text=re.sub(rb'kindle:embed:([0-9A-V]{4})',lambda m:b'kindle:embed:'+b32(int(m[1],32)+1).encode(),text)
    else:
        text=re.sub(rb'recindex="(\d{5})"',lambda m:b'recindex="%05d"'%(int(m[1])+1),text)
    chunks=[text[i:i+4096] for i in range(0,len(text),4096)]
    r0[0:2]=(1).to_bytes(2,'big'); r0[8:10]=len(chunks).to_bytes(2,'big'); r0[4:8]=len(text).to_bytes(4,'big')
    if hl>=0xE4: r0[0xF2:0xF4]=b'\0\0'
    shift=len(chunks)-ntext
    r0[108:112]=(first+shift).to_bytes(4,'big')
    resc=b'RESC'+b'\0'*12+b'<spine></spine>'
    return palm_build(book,[bytes(r0)]+chunks+recs[ntext+1:first]+[resc]+recs[first:])

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

    # 7. Kindlegen/KCC-style books (RESC record first), the v1.0 "书中没有图片" bug.
    kg=T/'kindlegen'; kg.mkdir()
    (kg/'mobi6-resc.mobi').write_bytes(with_resc_first((outs/'src.mobi').read_bytes()))
    roundtrip('MOBI6（首资源为 RESC）',kg/'mobi6-resc.mobi')
    if HAS_CALIBRE:
        (kg/'kf8-resc.azw3').write_bytes(with_resc_first((outs/'src.azw3').read_bytes()))
        roundtrip('KF8 AZW3（首资源为 RESC）',kg/'kf8-resc.azw3',lossless_png=False,tol=20,jpeg_exact=False)
    nofirst=bytearray((outs/'src.mobi').read_bytes()); r0=int.from_bytes(nofirst[78:82],'big')
    nofirst[r0+108:r0+112]=b'\xff\xff\xff\xff'
    (kg/'no-first-image.mobi').write_bytes(nofirst)
    r=conv('cbz',kg/'no-first-image.mobi',out=kg)
    check('首资源索引缺失时扫描全书图片',r.returncode==0 and '（12 页）' in r.stdout,r.stdout)
    recs=palm_records((outs/'src.mobi').read_bytes()); first=int.from_bytes(recs[0][108:112],'big')
    ph=[recs[i] if i<first or recs[i][:4] in (b'FLIS',b'FCIS') or i==len(recs)-1 else b'\xa0\xa0\xa0\xa0' for i in range(len(recs))]
    (kg/'placeholders.mobi').write_bytes(palm_build((outs/'src.mobi').read_bytes(),ph))
    r=conv('cbz',kg/'placeholders.mobi',out=kg)
    check('仅含高清占位符的书给出 .azw.res 说明',r.returncode==1 and 'azw.res' in r.stdout,r.stdout)
    r=subprocess.run([str(CLI),'--inspect',str(kg/'mobi6-resc.mobi')],capture_output=True,text=True)
    check('--inspect 输出结构摘要',r.returncode==0 and 'RESC×1' in r.stdout and 'jpg×' in r.stdout,r.stdout)

    # 8. Input format: content detection, forced readers, batch filtering.
    shutil.copy(outs/'src.mobi',T/'mystery.dat')
    r=conv('cbz',T/'mystery.dat',out=T)
    check('按内容识别（无扩展名线索的 MOBI）',r.returncode==0 and '（12 页）' in r.stdout,r.stdout)
    r=conv('cbz',batch,out=T,extra=['-f','mobi'])
    check('-f mobi 只处理 MOBI 文件',r.returncode==0 and '成功 1，' in r.stdout,r.stdout)
    r=conv('cbz',outs/'src.mobi',out=T,extra=['-f','pdf'])
    check('指定格式与内容不符时提示改用自动识别',r.returncode==1 and '自动识别' in r.stdout,r.stdout)
    r=conv('cbz',outs/'src.mobi',out=T,extra=['-f','mobi'])
    check('-f mobi 正常转换 MOBI',r.returncode==0,r.stdout)

    # 9. CBR output plumbing via a stand-in for RARLAB's rar (archives with zip so the result is readable).
    stub=T/'fake-rar'; log=T/'rar-args.txt'
    stub.write_text(f'#!/bin/sh\necho "$@" > "{log}"\n[ "$1" = a ] && [ "$2" = -m0 ] && [ "$3" = -ep1 ] || exit 9\nout="$5"; shift 5\nexec /usr/bin/zip -j -0 -q "$out" "$@"\n')
    stub.chmod(0o755)
    import os
    r=subprocess.run([str(CLI),'-t','cbr','-o',str(T),str(src)],capture_output=True,text=True,env={**os.environ,'COMICCONV_RAR':str(stub)})
    check('CBR 输出调用 rar（a -m0 -ep1）',r.returncode==0 and (T/'src.cbr').exists(),r.stdout+r.stderr)
    if (T/'src.cbr').exists(): roundtrip('CBR（模拟 rar）',T/'src.cbr')
    r=subprocess.run([str(CLI),'-t','cbr','-o',str(T),str(src)],capture_output=True,text=True,env={**os.environ,'COMICCONV_RAR':'/nonexistent'})
    check('未安装 rar 时 CBR 给出安装提示',r.returncode==1 and 'brew install --cask rar' in r.stdout,r.stdout)
    # 10. App model (checkboxes, multi-select, input filter, queue, backdrop) without UI.
    mh=T/'model'; mh.mkdir(); (mh/'out').mkdir()
    for ext in ['mobi','cbz','pdf','azw3']:
        if (outs/f'src.{ext}').exists(): shutil.copy(outs/f'src.{ext}',mh/f'src.{ext}')
    if not (mh/'src.azw3').exists(): shutil.copy(outs/'src.mobi',mh/'src.azw3')
    r=subprocess.run([str(HARNESS),str(mh),str(mh/'out')],capture_output=True,text=True,timeout=120,
                     env={**os.environ,'CFFIXED_USER_HOME':str(T/'home')})
    for line in r.stdout.splitlines():
        if line.startswith(('PASS ','FAIL ')): check('界面模型：'+line[5:],line.startswith('PASS'))
    check('界面模型测试正常结束',r.returncode==0 and 'MODEL OK' in r.stdout,r.stdout[-500:]+r.stderr[-500:])
    src_after=sorted(p.name for p in src.iterdir())
    check('源文件未被改动',src_after==sorted(p.name for p in order))

passed=all(r['passed'] for r in results)
(ROOT/'Tests/results.json').write_text(json.dumps({'passed':passed,'calibre':HAS_CALIBRE,'results':results},ensure_ascii=False,indent=2))
print(f"\n{sum(r['passed'] for r in results)}/{len(results)} passed")
sys.exit(0 if passed else 1)
