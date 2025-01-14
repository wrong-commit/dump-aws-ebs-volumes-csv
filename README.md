# How To 
1. Configure an AWS profile in `awscli` for the target audit environment   
2. Update the bash script with your AWS profile name 
3. Run `generate.sh`
4. When prompted enter output of command from each EC2 instance
5. Review output in Excel or with in terminal with `column -s, -t < example_output/ebs.csv | less -#2 -N -S`

# Output 

See `example_output/ebs.csv` to view the current application output. 

# Bugfixes & Improvements
[ ] nvme drives in the OS_VOLUME_NAME column do not contain their `/dev/` prefix   
[ ] support more than default region, iterate all regions  
[x] support prompting to paste in lsblk.txt and df.txt  
[ ] filter out windows VMs, test base AMI?   
[x] handle NVME drives and random ordering   

