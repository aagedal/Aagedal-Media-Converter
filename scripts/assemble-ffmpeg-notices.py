#!/usr/bin/env python3
"""Collect FFmpeg notices from the retained, attributed build workspace."""
from pathlib import Path
import hashlib,json,re,subprocess,tarfile
import argparse
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace',type=Path,required=True)
args=parser.parse_args()
workspace=args.workspace.resolve()
repo=Path(__file__).resolve().parents[1]
sources=workspace/'sources'
out=repo/'docs/provenance/4.4-local-builds/ffmpeg-attributed-build'
out.mkdir(parents=True,exist_ok=True)
# Preserve the exact scripts invoked, including the release-mirror correction.
for path in [workspace/'config.sh',*sorted((workspace/'scripts').glob('*.sh'))]:
 dest=out/'recipe'/path.relative_to(workspace);dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(path.read_bytes())
notices=[]
for top in sorted(p for p in sources.iterdir() if p.is_dir()):
 for path in sorted(top.rglob('*')):
  if not path.is_file() or any(part in {'.git','build','cmake-build','CMakeFiles','testdata'} for part in path.relative_to(top).parts):continue
  name=path.name.lower()
  if re.match(r'^(copying|license|licence|notice|copyright|patents|authors)([._-].*)?$',name) or name in {'ftl.txt','gplv2.txt','bsd.txt'}:
   data=path.read_bytes()
   try:text=data.decode('utf-8')
   except UnicodeDecodeError:text=data.decode('latin-1')
   # RTF manuals are not the source license; retain the plain source counterpart.
   if path.suffix.lower()=='.rtf':continue
   notices.append({'path':path.relative_to(workspace).as_posix(),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'text':text})
notice='FFmpeg 9.0.1 and source dependency notices\n\nThis application distributes a GPL version 3 or later FFmpeg build. The source\ncompanion supplied with this release contains its library sources and build\nscripts. Notices below cover those source distributions, including optional\nsource components; they do not imply every component is linked into FFmpeg.\n\n'
notice+='\n'.join('='*72+'\n'+n['path']+'\n'+'='*72+'\n\n'+n['text'] for n in notices)
(repo/'Licenses/ffmpeg-LICENSE.txt').write_text(notice)
records=[]
for p in sorted(sources.iterdir()):
 if p.is_file() and re.search(r'\.tar\.(gz|xz|bz2)$',p.name):
  records.append({'path':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
revisions=[]
for p in sorted(sources.iterdir()):
 if p.is_dir() and (p/'.git').exists():
  revisions.append({'directory':p.name,'revision':subprocess.check_output(['git','-C',str(p),'rev-parse','HEAD'],text=True).strip(),'remote':subprocess.check_output(['git','-C',str(p),'remote','get-url','origin'],text=True).strip()})
(out/'evidence.json').write_text(json.dumps({'buildRecipeRepository':'https://github.com/aagedal/ffmpeg-apple-silicon','downloadedArchives':records,'gitSources':revisions,'notices':[{k:v for k,v in n.items() if k!='text'} for n in notices]},indent=2)+'\n')
print('Collected',len(notices),'source notices,',len(notice),'characters')
