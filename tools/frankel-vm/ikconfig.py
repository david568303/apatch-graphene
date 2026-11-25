import sys,zlib
d=open(sys.argv[1],'rb').read()
i=d.find(b'IKCFG_ST')
if i<0: print('no ikconfig'); sys.exit(1)
z=d[i+8:]
o=zlib.decompressobj(16+zlib.MAX_WBITS)
sys.stdout.write(o.decompress(z).decode())
