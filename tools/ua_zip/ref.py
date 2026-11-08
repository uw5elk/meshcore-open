import re,json,math,collections,heapq
D=json.load(open('words.json')); WORDS=D['words']; MASS=D['mass']; N=len(WORDS)
IDX={w:i for i,w in enumerate(WORDS)}
UKL="абвгґдеєжзиіїйклмнопрстуфхцчшщьюя"
CH=list(UKL)+["'"]+list("abcdefghijklmnopqrstuvwxyz")+["-"]  # '-' unused in words; kept as END placeholder index
CH=list(UKL)+["'"]+list("abcdefghijklmnopqrstuvwxyz")   # 60 symbols
CH_END=len(CH)          # 60
PUNCT=list(".,!?:;-()\"/+%…\n*#@=_[]<>&|~^$\\")
# type symbols
T=['W_l_S','W_l','W_C_S','W_C','W_U_S','W_U','O_l_S','O_l','O_C_S','O_C','O_U_S','O_U','O_M_S','O_M','NUM','NUM_S','SPACE','PUNCT','PUNCT_S','RAW','PAD']
TI={n:i for i,n in enumerate(T)}
# intervals
starts=[0,1,2,3]
k=2
while starts[-1]<N:
    starts+= [2**k,3*2**(k-1)]; k+=1
starts=[s for s in starts if s<N]+[N]
# fix: ensure interval sizes are powers of two for offset bits; last interval truncated -> decoder bounds-checks
def interval_of(r):
    lo,hi=0,len(starts)-1
    while hi-lo>1:
        m=(lo+hi)//2
        if starts[m]<=r: lo=m
        else: hi=m
    return lo
def bits_for(i):
    size=starts[i+1]-starts[i]
    b=0
    while (1<<b)<size: b+=1
    return b
LETTER=re.compile(r"[а-щьюяіїєґa-z']",re.I)
def tokenize(text):
    toks=[];i=0;n=len(text)
    wordch=set(UKL+"abcdefghijklmnopqrstuvwxyz'"+UKL.upper()+"abcdefghijklmnopqrstuvwxyz".upper())
    while i<n:
        c=text[i]
        if c in wordch and c!="'":
            j=i
            while j<n and text[j] in wordch: j+=1
            w=text[i:j]
            while w.endswith("'"): w=w[:-1];j-=1   # trailing apostrophe -> separate punct/raw
            toks.append(('W',w));i=j
        elif c.isdigit() and c in '0123456789':
            j=i
            while j<n and text[j] in '0123456789': j+=1
            toks.append(('N',text[i:j]));i=j
        elif c==' ': toks.append(('SP',));i+=1
        elif c in PUNCT: toks.append(('P',c));i+=1
        else: toks.append(('R',c));i+=1
    return toks
def case_class(w):
    lo=w.lower()
    if w==lo: return 'l'
    if len(w)>=1 and w[0].upper()+w[1:].lower()==w and w[0]!=w[0].lower(): return 'C'
    if w.upper()==w and len(w)>=2: return 'U'
    return 'M'
def apply_case(lo,cl):
    if cl=='l': return lo
    if cl=='C': return lo[0].upper()+lo[1:]
    return lo.upper()
def stream(text):
    """list of (typeName, payload) with SPACE merged into preceding token."""
    toks=tokenize(text);out=[];i=0
    while i<len(toks):
        t=toks[i];sp=False
        if i+1<len(toks) and toks[i+1]==('SP',) and t[0] in('W','N','P'):
            sp=True
        if t[0]=='W':
            w=t[1];cl=case_class(w);lo=w.lower()
            if cl!='M' and lo in IDX:
                out.append(('W_%s%s'%(cl,'_S' if sp else ''),IDX[lo]))
            else:
                out.append(('O_%s%s'%(cl,'_S' if sp else ''),w))
        elif t[0]=='N':
            s=t[1]
            while len(s)>16:
                out.append(('NUM',s[:16]));s=s[16:]
            out.append(('NUM_S' if sp else 'NUM',s))
        elif t[0]=='SP': out.append(('SPACE',None))
        elif t[0]=='P': out.append(('PUNCT_S' if sp else 'PUNCT',t[1]))
        else: out.append(('RAW',t[1]))
        i+=2 if sp else 1
    return out
def huff_lengths(weights):
    h=[(w,i,None) for i,w in enumerate(weights)]
    heap=[(w,i,[i]) for i,w in enumerate(weights)]
    heapq.heapify(heap);L=[0]*len(weights);cnt=len(weights)
    while len(heap)>1:
        a=heapq.heappop(heap);b=heapq.heappop(heap)
        for s in a[2]+b[2]: L[s]+=1
        heapq.heappush(heap,(a[0]+b[0],cnt,a[2]+b[2]));cnt+=1
    return L
def canon(L):
    order=sorted(range(len(L)),key=lambda s:(L[s],s));code=0;prev=0;codes={}
    for s in order:
        code<<=(L[s]-prev);prev=L[s];codes[s]=(code,L[s]);code+=1
    return codes
class Tables: pass
def build_tables(samples):
    cnt_t=collections.Counter();cnt_p=collections.Counter();cnt_c=collections.Counter()
    for s in samples:
        for ty,p in stream(s):
            cnt_t[ty]+=1
            if ty.startswith('PUNCT'): cnt_p[p]+=1
            if ty.startswith('O_'):
                for ch in p.lower():
                    if ch in CH: cnt_c[ch]+=1
                cnt_c['END']+=1
    tw=[cnt_t[n]+0.3 for n in T]; tw[TI['PAD']]=1e-4
    pw=[cnt_p[c]+0.3 for c in PUNCT]
    # letter weights: from rare words
    lc=collections.Counter()
    for w in WORDS[8000:30000]:
        for ch in w: lc[ch]+=1
    cw=[lc[c]/len(WORDS[8000:30000])+cnt_c[c]*2.0+0.05 for c in CH]+[ (len(set(range(10)))) +cnt_c['END']+2.0]
    # intervals weights from mass
    iw=[0.0]*(len(starts)-1)
    tot=sum(MASS)
    for r,m in enumerate(MASS): iw[interval_of(r)]+=m/tot
    iw=[x*1000+1e-3 for x in iw]
    t=Tables();t.type_len=huff_lengths(tw);t.punct_len=huff_lengths(pw);t.char_len=huff_lengths(cw);t.iv_len=huff_lengths(iw)
    return t
class BW:
    def __init__(s): s.bits=[]
    def put(s,code,n):
        for i in range(n-1,-1,-1): s.bits.append((code>>i)&1)
    def tobytes(s):
        b=list(s.bits)
        while len(b)%8: b.append(1)
        return bytes(int(''.join(map(str,b[i:i+8])),2) for i in range(0,len(b),8))
def encode_bytes(text,t):
    ct=canon(t.type_len);cp=canon(t.punct_len);cc=canon(t.char_len);ci=canon(t.iv_len)
    bw=BW()
    for ty,p in stream(text):
        bw.put(*ct[TI[ty]])
        if ty.startswith('W_'):
            iv=interval_of(p);bw.put(*ci[iv]);b=bits_for(iv);bw.put(p-starts[iv],b)
        elif ty.startswith('O_'):
            cl=ty[2]
            for ch in p:
                lo=ch.lower()
                bw.put(*cc[CH.index(lo)])
                if cl=='M': bw.put(1 if ch!=lo else 0,1)
            bw.put(*cc[CH_END])
        elif ty.startswith('NUM'):
            bw.put(len(p)-1,4)
            for d in p: bw.put(int(d),4)
        elif ty.startswith('PUNCT'):
            bw.put(*cp[PUNCT.index(p)])
        elif ty=='RAW':
            u=p.encode('utf8');bw.put(len(u)-1,2)
            for x in u: bw.put(x,8)
    return bw.tobytes()
B94=''.join(chr(c) for c in range(0x21,0x7f))
def blk(r):
    c=1
    while 94**c<256**r: c+=1
    return c
def b94enc(data):
    out=[];i=0
    while i<len(data):
        chunk=data[i:i+13];n=int.from_bytes(chunk,'big');c=blk(len(chunk)) if len(chunk)<13 else 16
        s=[]
        for _ in range(c): s.append(B94[n%94]);n//=94
        out.append(''.join(reversed(s)));i+=13
    return ''.join(out)
def total_cost(text,t):
    b=encode_bytes(text,t)
    return len(b94enc(b))+2
