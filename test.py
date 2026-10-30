#!/usr/bin/env python3
"""End-to-end tests: every format round-trips page order, colors and (where promised) exact bytes.
Calibre, when installed, cross-checks the MOBI/EPUB/AZW3 output and supplies third-party MOBI/AZW3 input."""
from pathlib import Path
import io,json,os,shutil,subprocess,sys,tarfile,tempfile,zipfile
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

    def roundtrip(label,source,lossless_png=True,tol=14,expect=None,jpeg_exact=True):
        expect=want if expect is None else expect
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

    # 11. Batch naming.
    nm=T/'naming'; nm.mkdir()
    r=conv('cbz',batch,out=nm,extra=['--name','{标题} 第{序号}卷'])
    check('命名模板 + 自动两位序号',r.returncode==0 and sorted(p.name for p in nm.iterdir())==['src 第01卷.cbz','src 第02卷.cbz','src 第03卷.cbz'],str(sorted(p.name for p in nm.iterdir())))
    messy=nm/'messy'; messy.mkdir()
    shutil.copy(outs/'src.cbz',messy/'[某汉化组] 海贼王 (第1卷)【高清】.cbz')
    r=conv('cbz',messy/'[某汉化组] 海贼王 (第1卷)【高清】.cbz',out=messy,extra=['--strip-brackets'])
    check('去掉括号及其内容',(messy/'海贼王.cbz').exists(),str(list(messy.iterdir())))
    r=conv('epub',messy/'[某汉化组] 海贼王 (第1卷)【高清】.cbz',out=messy,extra=['--regex','--find','.*\\(第(\\d+)卷\\).*','--replace','One Piece Vol.$1','--name','{原名} - {页数}P'])
    check('正则查找替换 + {页数}',(messy/'One Piece Vol.1 - 12P.epub').exists(),r.stdout+str(list(messy.iterdir())))
    r=conv('pdf',src,out=nm,extra=['--name','a/b:c {序号}','--start','5','--pad','3'])
    check('非法字符替换、起始序号与位数',(nm/'a／b：c 005.pdf').exists(),r.stdout)
    r=conv('pdf',src,out=nm,extra=['--name','a/b:c {序号}','--start','5','--pad','3'])
    check('命名重复时自动编号',(nm/'a／b：c 005 (1).pdf').exists(),r.stdout)
    r=conv('cbz',src,out=nm,extra=['--name','{作者}  -  {原名}'])
    check('空作者留下的分隔符被清理',(nm/'src.cbz').exists(),r.stdout)
    r=conv('cbz',src,out=nm,extra=['--regex','--find','(unclosed'])
    check('无效正则在转换前报错',r.returncode==2 and '正则' in r.stderr,r.stderr)

    # 12. Security review fixes (Codex + DeepSeek review of v1.1.1).
    sec=T/'security'; (sec/'outside').mkdir(parents=True); (sec/'out').mkdir()
    shutil.copy(order[0],sec/'outside'/'secret.jpg')
    (sec/'outside'/'info.xml').write_text('<ComicInfo><Title>LEAKED-LOCAL-FILE</Title></ComicInfo>')
    import stat
    def zlink(z,name,target):
        i=zipfile.ZipInfo(name); i.external_attr=(stat.S_IFLNK|0o777)<<16; z.writestr(i,target)
    with zipfile.ZipFile(sec/'link-dir.epub','w') as z:
        z.writestr('mimetype','application/epub+zip')
        z.writestr('META-INF/container.xml','<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>')
        zlink(z,'imgs',str(sec/'outside'))
        z.writestr('content.opf','<package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest><item id="p" href="p.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="p"/></spine></package>')
        z.writestr('p.xhtml','<html><body><img src="imgs/secret.jpg"/></body></html>')
    r=conv('cbz',sec/'link-dir.epub',out=sec/'out')
    check('EPUB 符号链接目录不能读出包外文件',r.returncode==1 and not list((sec/'out').glob('*.cbz')),r.stdout)
    with zipfile.ZipFile(sec/'link-info.cbz','w') as z:
        zlink(z,'ComicInfo.xml',str(sec/'outside'/'info.xml'))
        zlink(z,'002.jpg',str(sec/'outside'/'secret.jpg'))
        z.writestr('001.jpg',order[2].read_bytes())
    r=conv('epub',sec/'link-info.cbz',out=sec/'out')
    with zipfile.ZipFile(sec/'out'/'link-info.epub') as z:
        opf=z.read('OEBPS/content.opf').decode()
    check('符号链接 ComicInfo 与图片被忽略',r.returncode==0 and 'LEAKED' not in opf and '（1 页）' in r.stdout,r.stdout)
    with zipfile.ZipFile(sec/'many.cbz','w') as z:
        for k in range(100_001): z.writestr(f'f{k}.txt','')
    r=conv('cbz',sec/'many.cbz',out=sec/'out')
    check('文件数量超限的压缩包被拒绝',r.returncode==1 and '超过 100000 个' in r.stdout,r.stdout[-300:])
    subprocess.run(['mkfile','-n','21g',str(sec/'big.bin')],check=True)
    subprocess.run(['/usr/bin/tar','--format','pax','-cSf',str(sec/'bomb.cbt'),'-C',str(sec),'big.bin'],check=True)
    (sec/'big.bin').unlink()
    r=conv('cbz',sec/'bomb.cbt',out=sec/'out')
    check('声明解开后超过 20 GB 的压缩包被拒绝',r.returncode==1 and ('上限' in r.stdout or '磁盘剩余空间' in r.stdout) and not any(sec.rglob('big.bin')),r.stdout)
    recs=palm_records((outs/'src.mobi').read_bytes()); r0=bytearray(recs[0])
    bomb=b'a'+bytes([0x80|0x00,0x0F])*30000   # each 2-byte code copies 10 bytes: ~300 KB from 60 KB
    r0[0:2]=(2).to_bytes(2,'big'); r0[8:10]=(1).to_bytes(2,'big')
    # One compressed text record replaces the original text records (record count shifts are fine:
    # firstImage still points at the first image because the text was a single record).
    assert int.from_bytes(recs[0][8:10],'big')==1
    (sec/'palmdoc-bomb.mobi').write_bytes(palm_build((outs/'src.mobi').read_bytes(),[bytes(r0),bomb]+recs[2:]))
    r=conv('cbz',sec/'palmdoc-bomb.mobi',out=sec/'out')
    check('PalmDOC 解压上限生效，转换回退为按记录顺序',r.returncode==0 and '异常庞大' in r.stdout,r.stdout)
    subprocess.run([str(FIX),'bigpdf',str(sec/'huge.pdf')],check=True)
    r=conv('cbz',sec/'huge.pdf',out=sec/'out')
    pages,_=cbz_pages(sec/'out'/'huge.cbz',sec/'huge') if r.returncode==0 else ([],'')
    c=colors(pages)
    check('超大 PDF 页面按 80 MP 上限渲染',len(c)==1 and c[0][3]*c[0][4]<=80_000_000 and c[0][3]>=8000,r.stdout+str(c))

    # Back-to-back repeats are dropped, deliberate later repeats kept.
    with zipfile.ZipFile(outs/'src.epub') as zin, zipfile.ZipFile(sec/'repeat.epub','w') as zout:
        for info in zin.infolist():
            data=zin.read(info.filename)
            if info.filename=='OEBPS/text/p0004.xhtml': data=data.replace(b'p0004.',b'p0001.').replace(b'.png"',b'.jpg"')
            zout.writestr(info,data)
    pages,_=roundtrip('EPUB 重复引用', sec/'repeat.epub', lossless_png=False, jpeg_exact=False, expect=want[:3]+[want[0]]+want[4:]) or ([],'')
    m=bytearray((outs/'src.mobi').read_bytes()); i=m.index(b'recindex="00004"'); m[i:i+16]=b'recindex="00001"'
    (sec/'repeat.mobi').write_bytes(m)
    roundtrip('MOBI 重复引用', sec/'repeat.mobi', lossless_png=False, jpeg_exact=False, expect=want[:3]+[want[0]]+want[4:])

    # Naming: token text inside metadata stays literal; names that clean to nothing get a fallback.
    nm2=T/'naming2'; nm2.mkdir()
    with zipfile.ZipFile(nm2/'meta.cbz','w') as z:
        z.writestr('001.jpg',order[0].read_bytes())
        z.writestr('ComicInfo.xml','<ComicInfo><Title>{序号}卷{原名}</Title></ComicInfo>')
    r=conv('cbz',nm2/'meta.cbz',out=nm2,extra=['--name','{标题}'])
    check('元数据中的变量文字不被二次替换',(nm2/'{序号}卷{原名}.cbz').exists(),r.stdout+str(list(nm2.iterdir())))
    shutil.copy(outs/'src.cbz',nm2/'....cbz')
    r=conv('cbz',nm2/'....cbz',out=nm2)
    check('清理后为空的名称回退为“未命名”',(nm2/'未命名.cbz').exists(),r.stdout+str(list(nm2.iterdir())))

    # Stale work directories from crashed runs are swept; fresh ones are kept.
    # Foundation ignores TMPDIR here, so use the real per-user temp dir with uniquely named probes.
    import uuid
    real_tmp=Path(subprocess.run(['getconf','DARWIN_USER_TEMP_DIR'],capture_output=True,text=True,check=True).stdout.strip())
    old_dir=real_tmp/f'ComicConverter-{str(uuid.uuid4()).upper()}'; new_dir=real_tmp/f'ComicConverter-{str(uuid.uuid4()).upper()}'
    foreign=real_tmp/f'ComicConverter-not-ours-{uuid.uuid4()}'
    for d in (old_dir,new_dir,foreign): d.mkdir()
    os.utime(old_dir,(0,1_600_000_000)); os.utime(foreign,(0,1_600_000_000))
    subprocess.run([str(CLI),'-t','cbz','-o',str(nm2),str(src)],capture_output=True)
    swept=not old_dir.exists() and new_dir.exists() and foreign.exists()
    for d in (old_dir,new_dir,foreign): shutil.rmtree(d,ignore_errors=True)
    check('只清理本程序格式的过期临时目录',swept)

    # 13. Third-round fixes (second Codex + DeepSeek review).
    r3=T/'round3'; r3.mkdir()
    big=r3/'pattern.cbz'
    with zipfile.ZipFile(big,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('001.jpg',order[0].read_bytes()); z.writestr('filler.bin',b'ab'*(32<<20))
    r=subprocess.run([str(CLI),'-t','cbz','-o',str(r3),str(big)],capture_output=True,text=True,env={**os.environ,'COMICCONV_MAX_EXPAND_MB':'8'})
    check('声明大小超过上限时解压前拒绝',r.returncode==1 and '上限' in r.stdout,r.stdout)
    wd=r3/'wd'
    out=subprocess.run([str(FIX),'watchdog',str(big),str(wd),str(8<<20)],capture_output=True,text=True).stdout
    check('解压中途超过上限时终止并删除已解出内容','stopped' in out and '已停止' in out and not wd.exists(),out)
    out=subprocess.run([str(FIX),'watchdog',str(outs/'src.cbz'),str(r3/'wd-ok'),str(1<<30)],capture_output=True,text=True).stdout
    check('未超限时正常解压',out.strip()=='extracted',out)
    root=r3/'root'; root.mkdir(); (root/'ok.txt').write_text('hello'); (r3/'outside.txt').write_text('secret')
    os.symlink(r3/'outside.txt',root/'link.txt'); os.symlink(r3,root/'dirlink')
    def rc(f,limit=1000): return subprocess.run([str(FIX),'readcontained',str(f),str(root),str(limit)],capture_output=True,text=True).stdout.strip()
    check('安全读取：目录内普通文件可读',rc(root/'ok.txt')=='read 5')
    check('安全读取：拒绝符号链接文件',rc(root/'link.txt').startswith('refused'))
    check('安全读取：拒绝经由符号链接目录逃出',rc(root/'dirlink'/'outside.txt').startswith('refused'))
    check('安全读取：拒绝超过大小上限',rc(root/'ok.txt',limit=3).startswith('refused'))
    import tarfile
    with tarfile.open(r3/'spaces.cbt','w',format=tarfile.USTAR_FORMAT) as t:
        for i,pg in enumerate(order[:2]):
            info=t.gettarinfo(str(pg),arcname=f'{i}.{pg.suffix[1:]}'); info.uname='John Smith'; info.gname='Comic Group'
            with open(pg,'rb') as f: t.addfile(info,f)
    r=conv('cbz',r3/'spaces.cbt',out=r3)
    check('属主/属组含空格的 TAR 可正常读取',r.returncode==0 and '（2 页）' in r.stdout,r.stdout)
    subprocess.run(['mkfile','-n','800m',str(r3/'huge.mobi')],check=True)
    r=conv('cbz',r3/'huge.mobi',out=r3)
    check('超过 700 MB 的 MOBI 被拒绝',r.returncode==1 and '700 MB' in r.stdout,r.stdout)
    r=subprocess.run([str(CLI),'--inspect',str(r3/'huge.mobi')],capture_output=True,text=True)
    check('--inspect 同样遵守 700 MB 上限','700 MB' in r.stdout,r.stdout)
    (r3/'huge.mobi').unlink()
    with zipfile.ZipFile(r3/'two-info.cbz','w') as z:
        z.writestr('001.jpg',order[0].read_bytes())
        z.writestr('a/b/ComicInfo.xml','<ComicInfo><Title>Deep</Title></ComicInfo>')
        z.writestr('ComicInfo.xml','<ComicInfo><Title>Shallow</Title></ComicInfo>')
    conv('epub',r3/'two-info.cbz',out=r3)
    with zipfile.ZipFile(r3/'two-info.epub') as z: check('多个 ComicInfo 时取最浅层',b'<dc:title>Shallow' in z.read('OEBPS/content.opf'))
    dang=r3/'dangling'; dang.mkdir(); os.symlink('/nonexistent/target',dang/'src.cbz')
    r=conv('cbz',src,out=dang)
    check('悬空符号链接占用的名称被跳过',(dang/'src (1).cbz').exists() and os.path.islink(dang/'src.cbz'),r.stdout)

    # 14. Fourth-round fixes (third review).
    r4=T/'round4'; r4.mkdir()
    payload=order[0].read_bytes()+b'\0'*(2<<20)          # a 2 MB "page"
    with tarfile.open(r4/'fake-owner.cbt','w',format=tarfile.USTAR_FORMAT) as t:
        i=tarfile.TarInfo('001.jpg'); i.size=len(payload); i.uname='x 5 Jan 1 2020'; i.gname='g 7 Feb 2 2021'
        t.addfile(i,io.BytesIO(payload))
    r=subprocess.run([str(CLI),'-t','cbz','-o',str(r4),str(r4/'fake-owner.cbt')],capture_output=True,text=True,env={**os.environ,'COMICCONV_MAX_EXPAND_MB':'1'})
    check('属主名中伪造的大小字段不影响统计',r.returncode==1 and '上限' in r.stdout,r.stdout)
    r=conv('cbz',r4/'fake-owner.cbt',out=r4)
    check('同一个包在默认上限下正常转换',r.returncode==0,r.stdout)
    subprocess.run(['mkfile','-n','1g',str(r4/'sparse.bin')],check=True)
    subprocess.run(['/usr/bin/tar','--format','pax','-cSf',str(r4/'sparse.cbt'),'-C',str(r4),'sparse.bin'],check=True)
    (r4/'sparse.bin').unlink()
    out=subprocess.run([str(FIX),'watchdog',str(r4/'sparse.cbt'),str(r4/'wd'),str(8<<20)],capture_output=True,text=True).stdout
    check('稀疏文件按内容大小计入解压上限','stopped' in out and not (r4/'wd').exists(),out)
    r=subprocess.run([str(CLI),'-t','cbz','-o',str(r4),str(outs/'src.cbz')],capture_output=True,text=True,env={**os.environ,'COMICCONV_MAX_EXPAND_MB':'99999999999999999'})
    check('环境变量填入极大值不会溢出崩溃',r.returncode==0,r.stdout+r.stderr)
    subprocess.run(['mkfile','-n','600m',str(r4/'huge.jpg')],check=True)
    subprocess.run(['/usr/bin/tar','--format','pax','-cSf',str(r4/'huge-page.cbt'),'-C',str(r4),'huge.jpg'],check=True)
    (r4/'huge.jpg').unlink()
    r=conv('cbz',r4/'huge-page.cbt',out=r4)
    check('超过 512 MB 的单页被拒绝',r.returncode==1 and '512 MB' in r.stdout,r.stdout)

    # 15. Fifth-round fixes: declared sizes near Int64.max must reject, not crash.
    r5=T/'round5'; r5.mkdir()
    def ustar(name,size,typeflag=tarfile.REGTYPE):
        i=tarfile.TarInfo(name); i.size=size; i.type=typeflag; return i.tobuf(format=tarfile.USTAR_FORMAT)
    def pax_size(size):
        rec=f' size={size}\n'.encode()
        n=next(len(rec)+d for d in range(1,25) if len(str(len(rec)+d))==d)
        body=str(n).encode()+rec
        return ustar('PaxHeader',len(body),tarfile.XHDTYPE)+body+b'\0'*((512-len(body)%512)%512)
    crafted=ustar('a.jpg',1000)+b'h'*1000+b'\0'*24+pax_size(9223372036854775000)+ustar('b.jpg',0)+b'\0'*1024
    (r5/'overflow.cbt').write_bytes(crafted)
    r=conv('cbz',r5/'overflow.cbt',out=r5)
    check('声明接近 Int64 上限的条目被拒绝而不是崩溃',r.returncode==1 and ('大小异常' in r.stdout or '上限' in r.stdout),f'exit={r.returncode} '+r.stdout)
    src_after=sorted(p.name for p in src.iterdir())
    check('源文件未被改动',src_after==sorted(p.name for p in order))

passed=all(r['passed'] for r in results)
(ROOT/'Tests/results.json').write_text(json.dumps({'passed':passed,'calibre':HAS_CALIBRE,'results':results},ensure_ascii=False,indent=2))
print(f"\n{sum(r['passed'] for r in results)}/{len(results)} passed")
sys.exit(0 if passed else 1)
