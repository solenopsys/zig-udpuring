
# 1 thread 

```
Performance: 1354394 req/s, 1872.89 MB/s
Performance: 1388662 req/s, 1920.28 MB/s
Performance: 1389951 req/s, 1922.06 MB/s
Performance: 1354557 req/s, 1873.12 MB/s
Performance: 1352102 req/s, 1869.72 MB/s
Performance: 1390523 req/s, 1922.85 MB/s
Performance: 1349062 req/s, 1865.52 MB/s
Performance: 1367959 req/s, 1891.65 MB/s
Performance: 1328991 req/s, 1837.77 MB/s
```


# usage 
zig run -O ReleaseFast src/rps.zig 

sudo bash ./bn.sh



echo "Hello, World!" | nc -u 192.168.1.1 8888

# TODO
Нужно оптимизировать udp.zig так как old/udp.zig  обрабатывать 1.35 миллионва сообщений в секунду а просто udp.zig 0.9 миллионва сообщений в секунду