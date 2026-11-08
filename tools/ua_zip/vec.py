import json
from ref import *
sample=[l.strip() for l in open('sample.txt',encoding='utf8') if l.strip()]
arb=json.load(open('/root/meshcore-open/lib/l10n/app_uk.arb'))
ui=[v for k,v in arb.items() if not k.startswith('@') and isinstance(v,str) and len(v)<150 and len(v)>10]
t=build_tables(ui+sample*5)
extra=["Привіт, UW5ELK! Я на 433.775 МГц, SNR 9.5 дБ 😀","McDonald's і ёлка\tтест","Тест  двох  пробілів ","73! Slava Ukraini, DX QSO RSSI -85 дБм","xyzzy qwertyuiop ґанок Їжак ЄВРО ПРИВІТ","1234567890123456789012 ok","м'ясо п'ять 'лапки' o'clock","Рядок1\nРядок2: (дужки) \"лапки\" a/b 50% #тег @ім'я","Z","а"]
msgs=sample+extra
vs=[]
for m in msgs:
    vs.append((m,'z:'+b94enc(encode_bytes(m,t))))
json.dump(vs,open('vectors.json','w'),ensure_ascii=False,indent=0)
u=sum(len(m.encode()) for m,_ in vs);z=sum(len(z) for _,z in vs);print(u,z)
for m,z in vs[-10:]: print(len(m.encode()),len(z))
