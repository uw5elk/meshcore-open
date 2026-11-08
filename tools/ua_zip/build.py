import re,json,math,collections,heapq,sys
from wordfreq import top_n_list,word_frequency
import pymorphy3
N=int(sys.argv[1]) if len(sys.argv)>1 else 70000
UK=re.compile(r"^[а-щьюяіїєґ']+$"); EN=re.compile(r"^[a-z']+$")
morph=pymorphy3.MorphAnalyzer(lang='uk')
W=collections.defaultdict(float)
for w in top_n_list('uk',443084):
    w2=w.replace('’',"'").replace('ʼ',"'")
    if not UK.match(w2) or len(w2)>24 or w2.startswith("'") or w2.endswith("'"): continue
    if len(w2)==1 and w2 not in 'вуійзаоясбж': continue
    if not morph.parse(w2)[0].is_known and morph.parse(w2)[0].score<0.5: continue
    W[w2]+=word_frequency(w,'uk')*0.85
for w in top_n_list('en',25000):
    if EN.match(w) and len(w)<=20 and not (len(w)==1 and w not in 'ai'):
        W[w]+=word_frequency(w,'en')*0.15
ranked=sorted(W.items(),key=lambda x:-x[1])
ref=ranked[min(4000,len(ranked)-1)][1]
tech=[t.lower() for t in open('tech.txt',encoding='utf8').read().split()]
for t in tech:
    t=t.replace('’',"'")
    if UK.match(t) or EN.match(t): W[t]=max(W.get(t,0),ref)
arb=json.load(open('/root/meshcore-open/lib/l10n/app_uk.arb'))
ref2=ranked[min(9000,len(ranked)-1)][1]
for k,v in arb.items():
    if k.startswith('@') or not isinstance(v,str):continue
    for t in re.findall(r"[а-щьюяіїєґ']+|[a-z']+",v.lower()):
        if (UK.match(t) or EN.match(t)) and len(t)<=24: W[t]=max(W.get(t,0),ref2)
ranked=sorted(W.items(),key=lambda x:(-x[1],x[0]))[:N]
words=[w for w,_ in ranked]; mass=[f for _,f in ranked]
json.dump({'words':words,'mass':mass},open('words.json','w'),ensure_ascii=False)
print(len(words),words[:15],words[-5:])
