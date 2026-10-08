import sys, calendar
sys.path.insert(0,'.')
import bt
SPLIT = calendar.timegm((2026,4,1,0,0,0))
def line(sym,P):
    tr=bt.run(sym,P)
    a=[t for t in tr if t[0]<SPLIT]; b=[t for t in tr if t[0]>=SPLIT]
    def f(x):
        if not x: return 'n=0'
        rs=[t[1] for t in x]; w=sum(r for r in rs if r>0); l=-sum(r for r in rs if r<0)
        return 'n=%d exp=%+.2f pf=%.2f'%(len(rs),sum(rs)/len(rs),w/l if l else 9.9)
    s=bt.stats(tr,0.75)
    return '%-10s all[n=%d exp=%+.2f pf=%.2f dd=%.1f%% ret=%+.1f%%] | train %s | test %s'%(sym,s.get('n',0),s.get('exp',0),s.get('pf',0),s.get('dd',0),s.get('ret',0),f(a),f(b))
if __name__=="__main__":
    cfgs={
     'A: sl0.15 sans filtre vol':dict(slval=0.15,vol=None),
     'B: sl0.10 sans filtre vol':dict(slval=0.10,vol=None),
     'C: sl0.20 sans filtre vol':dict(slval=0.20,vol=None),
     'D: sl0.15 + filtre vol':dict(slval=0.15),
    }
    for name,P in cfgs.items():
        print('==',name)
        for sym in ['EURUSD','GBPUSD','USDJPY','NAS100.fs','XAGUSD','XAUUSD']:
            Q=dict(P)
            if sym=='XAUUSD': Q.update(slmode='abs',slval=15,vol='abs',volval=1.5) if name.startswith('D') else Q
            print(line(sym,Q))
