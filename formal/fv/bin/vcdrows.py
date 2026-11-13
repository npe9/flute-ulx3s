import sys
v=open(sys.argv[1]).read(); want=sys.argv[2].split(',')
ids={}; vals={}; rows=[]; scope=[]; t=None
for line in v.split('\n'):
    line=line.strip()
    if line.startswith('$scope'): scope.append(line.split()[2])
    elif line.startswith('$upscope'): scope.pop()
    elif line.startswith('$var'):
        p=line.split(); ids.setdefault(p[3],[]).append('.'.join(scope[1:]+[p[4]]))
    elif line.startswith('#'):
        if t is not None: rows.append((t,dict(vals)))
        t=int(line[1:])
    elif line and line[0] in '01xz' and not line.startswith('$'):
        for n in ids.get(line[1:],[]): vals[n]=line[0]
    elif line.startswith('b'):
        b,i=line.split()
        for n in ids.get(i,[]): vals[n]=b[1:]
rows.append((t,dict(vals)))
for t,vv in rows[::int(sys.argv[3]) if len(sys.argv)>3 else 2]: print(t,{w:vv.get(w,'?') for w in want})
