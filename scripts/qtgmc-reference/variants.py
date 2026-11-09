"""Compare QTGMC reference variants against bwdif (needs numpy and ffmpeg)."""
import numpy as np, eval as E, qtgmc_ref as Q, sys
E.W,E.H,E.NF=360,288,16
Q.SEARCH_SAMPLER = Q.bilinear
clips={"ts":E.testsrc(),"pan":E.procedural_pan()}
class Base(Q.Params): pass
def V(**kw): return type("P",(Base,),kw)
variants={
 "medium (app default)":V(),
 "slow-like (tr2=2)":V(tr2=2),
 "no lossless":V(lossless=False),
 "lossless without de-comb":V(lossless_fix=False),
}
def comb(a, gt):
  v=[]
  for i in range(3,len(a)-3):
    e=np.clip(a[i],0,1)-gt[i]; c=e[1:-1]-(e[:-2]+e[2:])/2; v.append(np.mean(np.abs(c))*255)
  return np.mean(v)
for name,gt in clips.items():
  fr=E.interlace(gt); gt=gt[:len(fr)*2]
  o=E.ffmpeg_deint(fr,"bwdif=mode=send_field:parity=tff:deint=all")
  print(name,"bwdif",round(E.psnr(o,gt),2),round(E.flicker(o,gt),2),"comb",round(comb(o,gt),2),flush=True)
  for vn,P in variants.items():
    out=Q.deinterlace(fr,True,P=P)["final"]
    print(name,vn,round(E.psnr(out,gt),2),round(E.flicker(out,gt),2),"comb",round(comb(out,gt),2),flush=True)
