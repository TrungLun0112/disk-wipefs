```
apt install git make gcc -y
git clone https://github.com/TrungLun0112/disk-wipefs.git
cd disk-wipefs
chmod +x disk-wipefs.sh

Cách sử dụng:
./disk-wipefs.sh <start_letter> [end_letter] [--auto|--manual]

Ví dụ: 
./disk-wipefs.sh b d        # clean sdb to sdd, ask confirm each disk
./disk-wipefs.sh f --auto   # clean sdf only, no confirm
```
