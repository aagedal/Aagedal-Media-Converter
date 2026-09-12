import pathlib,json,re,hashlib,tarfile,io,gzip
import argparse
parser=argparse.ArgumentParser(description='Rebuild AVM notices and the Eigen source companion from retained sources.')
parser.add_argument('--source-root', type=pathlib.Path, required=True)
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]; src=args.source_root.resolve(); base=root/'docs/provenance/4.4-local-builds/avm-dependencies'; idx=json.loads((base/'compiler-inputs.json').read_text())
for files in idx['components'].values():
 for path, expected in files.items():
  if hashlib.sha256((src/path).read_bytes()).hexdigest()!=expected: raise SystemExit('Source drift: '+path)
# Capture whole comment blocks carrying notices, anywhere in selected source files.
pat=re.compile(r'/\*.*?\*/|(?:^[ \t]*//[^\n]*(?:\n|$))+',re.M|re.S)
blocks={}
for group,files in idx['components'].items():
 for f in files:
  text=(src/f).read_text(errors='replace')
  for m in pat.finditer(text):
   block=m.group().strip()
   if re.search(r'copyright|redistribution and use|permission is hereby granted|public domain|Cephes|sse math library',block,re.I):blocks.setdefault(block,set()).add(str(pathlib.Path(f)))
out=['AVM dependency file-level copyright and permission notices','Extracted verbatim comment blocks from the retained compiler inputs. Paths identify source attribution; conditional platform code may not be linked.']
for block,files in sorted(blocks.items(),key=lambda item:sorted(item[1])[0]):out+=['\n'+'='*78,'Sources: '+', '.join(sorted(files)),block]
(base/'file-level-NOTICES.txt').write_text('\n\n'.join(out)+'\n')
# Retain exactly the full Eigen headers and licenses, without unrelated benchmark programs.
selected=[p for p in (src/'build_arm64/eigen').rglob('*') if p.is_file() and (p.relative_to(src/'build_arm64/eigen').parts[0] in ('Eigen','unsupported') or p.name.startswith('COPYING.'))]
archive=root/'build/attribution/avm-eigen-source.tar.gz';archive.parent.mkdir(parents=True,exist_ok=True)
with archive.open('wb') as raw:
 with gzip.GzipFile(fileobj=raw,mode='wb',mtime=0,filename='') as gz:
  with tarfile.open(fileobj=gz,mode='w') as tar:
   for p in sorted(selected):
    data=p.read_bytes(); info=tarfile.TarInfo('eigen/'+str(p.relative_to(src/'build_arm64/eigen')));info.size=len(data);info.mode=0o644;tar.addfile(info,io.BytesIO(data))
meta={'component':'AVM Eigen','path':str(archive.relative_to(root)),'bytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest()}
(base/'eigen-source-archive.json').write_text(json.dumps(meta,indent=2)+'\n'); print(meta); print(len(blocks),'notice blocks',len(selected),'Eigen source files')

sections = [('AVM LICENSE', base.parent/'avm-source-LICENSE.txt'), ('AVM PATENTS', base.parent/'avm-source-PATENTS.txt')]
for component in json.loads((base/'inventory.json').read_text())['components']:
 for record in component['retainedFiles']:
  path=record['snapshotPath']
  if path.endswith('.cmake') or pathlib.Path(path).name.startswith('README.lib'): continue
  sections.append((path,base/path))
for path in ['libyuv/LICENSE','libyuv/PATENTS','libyuv/AUTHORS','libyuv/upstream-file-NOTICES.txt','tensorflow/nested/fft2d-LICENSE','tensorflow/nested/xla-LICENSE','tensorflow/nested/tsl-LICENSE','file-level-NOTICES.txt']:
 sections.append((path,base/path))
notice=['AVM encoder and decoder — third-party notices',
 'AVM upstream: https://gitlab.com/AOMediaCodec/avm\nRetained AVM revision: 000682c868c9c265fe0bd5b552a8d10ec49ac9a4',
 'These notices cover AVM and all 17 dependency groups appearing in the retained build compiler records, including conditional code and headers. Inclusion does not imply every component is used in every operation.',
 'Eigen Source Code Form (MPL 2.0) is supplied in avm-eigen-source.tar.gz in the source companion accompanying this application release. It contains the retained Eigen headers, supporting source files, and licenses. You may use and modify that source under its included licenses. Retained sources are used because the build selected local directories; no unverified upstream version is asserted.',
 'libyuv notices were recovered from the official version 1456 revision 7cd7f5a80fa7d63cdd0ca3b7e11447b8e6a1e7ec: https://chromium.googlesource.com/libyuv/libyuv/+/7cd7f5a80fa7d63cdd0ca3b7e11447b8e6a1e7ec/ . The compiled subset differs only in AOM copyright headers and one renamed-project comment. Both upstream and retained notices are preserved.']
for title,path in sections: notice+=['='*78+'\n'+title+'\n'+'='*78,path.read_text()]
(root/'Licenses/avm-LICENSE.txt').write_text('\n\n'.join(notice)+'\n')
