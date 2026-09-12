#!/usr/bin/env python3
from pathlib import Path
import tarfile,hashlib,json,re,subprocess
repo=Path(__file__).resolve().parents[4]
import argparse
parser=argparse.ArgumentParser(description='Preserve reviewed FFmpeg source trees and replay recipes.')
parser.add_argument('--workspace',type=Path,required=True)
workspace=parser.parse_args().workspace.resolve()
evidence=repo/'docs/provenance/4.4-local-builds/ffmpeg-attributed-build'
# A separate replay recipe always rebuilds existing source trees. The original
# scripts placed some compilation inside download-only guards.
recipe=evidence/'rebuild';recipe.mkdir(exist_ok=True)
for source in [workspace/'config.sh',*sorted((workspace/'scripts').glob('*.sh'))]:
 lines=source.read_text().splitlines(keepends=True)
 i=0
 while i<len(lines):
  if re.match(r'^if \[ ! -d ',lines[i]):
   depth=1;j=i+1
   while j<len(lines) and depth:
    if re.match(r'^\s*if\b',lines[j]):depth+=1
    if re.match(r'^\s*fi\s*$',lines[j]):depth-=1
    j+=1
   block=lines[i:j]
   tar=next((k for k,l in enumerate(block) if re.match(r'\s*tar xf ',l)),None)
   if tar is not None and any(re.match(r'\s*(make |cmake |\./configure)',l) for l in block[tar+1:]):
    block=block[:tar+1]+['fi\n']+block[tar+1:-1]
    lines[i:j]=block
  i+=1
 text=''.join(lines)
 if source.name=='09-libjxl.sh':text=text.replace('./deps.sh','# All selected dependency sources are included in this source companion.')
 # CMake may find the Homebrew prefix otherwise; all third-party inputs must be
 # the retained source/prefix. The build already sets pkg-config isolation.
 target=recipe/source.relative_to(workspace);target.parent.mkdir(exist_ok=True,parents=True);target.write_text(text)
steps=['02-x264.sh','03-x265.sh','04-libvpx.sh','05-libaom.sh','06-svt-av1.sh','07-vvenc.sh','09-libjxl.sh','10-audio.sh','10a-libwebp.sh','10c-theora.sh','10e-openjpeg.sh','11-extras.sh','11a-whisper.sh','11b-vmaf.sh','12-ffmpeg.sh']
(recipe/'rebuild.sh').write_text('#!/bin/bash\nset -euo pipefail\ncd "$(dirname "$0")"\nexport WORKSPACE="$PWD"\n# Override FFMPEG_METALCC/FFMPEG_METALLIB if Xcode cannot locate Metal.\n'+''.join('bash scripts/'+s+'\n' for s in steps))
(recipe/'README.md').write_text('FFmpeg 9.0.1 corresponding source\n\nInstall Xcode command-line tools and Metal compiler, CMake, Meson, Ninja, pkg-config, and standard build utilities. Extract the source companion into a writable directory, then run bash rebuild.sh. All source directories used by this build are included. Test media, downloaded duplicates and build outputs are omitted. Build scripts rebuild existing sources rather than skipping them. You may edit library sources before rebuilding; generated outputs go to compiled/ and dist/. Preserve modified sources and notices when redistributing changes.\n\nThe original exact invoked scripts, version/source evidence, and configuration are in build-evidence/. The replay recipe differs only to rebuild existing source directories and avoid downloading libjxl dependencies already included. Xcode/Apple SDKs and system libraries are not redistributed. Local Git metadata is retained only for the two public source clones so their version generators retain the revision.\n')
archive=repo/'build/attribution/ffmpeg-9.0.1-source.tar.gz'
excluded_dirs={'build','cmake-build','CMakeFiles','.libs','.deps','autom4te.cache','downloads','testdata'}
excluded_suffixes={'.o','.a','.lo','.la','.d','.dylib','.so','.air','.metallib','.pyc'}
files=[]
with tarfile.open(archive,'w:gz',compresslevel=6) as tar:
 for path in sorted((workspace/'sources').rglob('*')):
  rel=path.relative_to(workspace)
  if any(part in excluded_dirs for part in rel.parts):continue
  if len(rel.parts)==2 and path.is_file():continue # download archives; extracted sources included
  if path.is_file() and path.suffix in excluded_suffixes:continue
  if path.is_symlink():
   if not path.resolve().is_relative_to(workspace):raise ValueError('External source symlink: '+str(path))
  if path.is_file():
   with path.open('rb') as handle: magic=handle.read(4)
   if magic in [bytes.fromhex(x) for x in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca','7f454c46']]:continue
   data=path.read_bytes();files.append({'path':rel.as_posix(),'sha256':hashlib.sha256(data).hexdigest()})
   tar.add(path,arcname=rel.as_posix(),recursive=False)
 for path in sorted(recipe.rglob('*')):
  if path.is_file():tar.add(path,arcname=path.relative_to(recipe).as_posix())
 for path in sorted(evidence.rglob('*')):
  if path.is_file() and 'rebuild' not in path.relative_to(evidence).parts and path.name!='source-archive.json':tar.add(path,arcname='build-evidence/'+path.relative_to(evidence).as_posix())
 tar.add(repo/'Licenses/ffmpeg-LICENSE.txt',arcname='LICENSES.txt')
metadata={'component':'FFmpeg 9.0.1 build','path':archive.relative_to(repo).as_posix(),'bytes':archive.stat().st_size,'sha256':hashlib.file_digest(archive.open('rb'),'sha256').hexdigest()}
(evidence/'source-archive.json').write_text(json.dumps({'archive':metadata,'files':files},indent=2)+'\n')
print(json.dumps(metadata))
