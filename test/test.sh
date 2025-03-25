# benchmarking the rust app

# python3 -m http.server
http://[::]:8000/10gbfile.bin


for i in {1..10}; do
    offset=$(( (i-1) * 1073741824 ))  # 10GB/10 = 1GB per client
    curl -s -o /dev/null --limit-rate 100M --range $offset-$(( offset + 1073741823 )) \
         "http://localhost:8000/10gbfile.bin" &
done
wait

# my rust app

for i in {1..10}; do
    offset=$(( (i-1) * 1073741824 ))  # 10GB/10 = 1GB per client
    curl -s -o /dev/null --limit-rate 100M --range $offset-$(( offset + 1073741823 )) \
         "http://localhost:3000/files/10gbfile.bin" &
done
wait
