import sys, itertools, calendar
sys.path.insert(0,'.')
import bt
SPLIT = calendar.timegm((2026,4,1,0,0,0))
def pooled(syms, P):
    a=[];b=[]
    for s in syms:
        for t in bt.run(s,P):
            (a if t[0]<SPLIT else b).append(t)
    return a,b
def summ(x):
    if not x: return (0,0,0)
    rs=[t[1] for t in x]; w=sum(r for r in rs if r>0); l=-sum(r for r in rs if r<0)
    return (len(rs), sum(rs)/len(rs), w/l if l else 9.9)
if __name__=="__main__":
    syms=sys.argv[1].split(',')
    grid=dict(rr=[2,3,4], minfvg=[0.2,0.5,1.0], bos=[True,False], slval=[0.15,0.25,0.4], vol=["none","ratio"], ladder=[True,False])
    keys=list(grid)
    res=[]
    for vals in itertools.product(*[grid[k] for k in keys]):
        P=dict(zip(keys,vals))
        if P["vol"]=="none": P["vol"]=None
        a,b=pooled(syms,P)
        sa,sb=summ(a),summ(b)
        res.append((P,sa,sb))
    res.sort(key=lambda r: min(r[1][1] if r[1][0]>=20 else -9, r[2][1] if r[2][0]>=20 else -9), reverse=True)
    for P,sa,sb in res[:12]:
        print({k:(v if v is not None else 'none') for k,v in P.items()}, 'train n=%d exp=%.2f pf=%.2f | test n=%d exp=%.2f pf=%.2f'%(sa[0],sa[1],sa[2],sb[0],sb[1],sb[2]))
    print('configs', len(res))
