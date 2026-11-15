import pefile,os,sys,shutil
out,src=sys.argv[1],sys.argv[2]
sysd=os.path.join(os.environ.get('WINDIR','C:\\Windows'),'System32')
changed=True
while changed:
    changed=False
    have={f.lower() for f in os.listdir(out)}
    for f in list(os.listdir(out)):
        if not f.lower().endswith(('.dll','.exe')): continue
        pe=pefile.PE(os.path.join(out,f),fast_load=True)
        pe.parse_data_directories([pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT']])
        for e in getattr(pe,'DIRECTORY_ENTRY_IMPORT',[]):
            n=e.dll.decode().lower()
            if n in have or n.startswith('api-ms-') or os.path.exists(os.path.join(sysd,n)): continue
            cand=[x for x in os.listdir(src) if x.lower()==n]
            if cand:
                shutil.copy(os.path.join(src,cand[0]),out); print('closure copied',cand[0]); changed=True; have.add(n)
            else: print('UNRESOLVED',n,'needed by',f)
