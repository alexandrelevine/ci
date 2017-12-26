#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/functions"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

# check if environment is present
if $virsh_cmd list --all | grep -q "${job_prefix}-cont" ; then
  echo 'ERROR: environment present. please clean up first'
  $virsh_cmd list --all | grep "${job_prefix}-"
  exit 1
fi

create_network $nname $addr
create_network $nname_ext $addr_ext

# create pool
$virsh_cmd pool-info $poolname &> /dev/null || create_pool $poolname
pool_path=$(get_pool_path $poolname)

function run_machine() {
  local name="$1"
  local cpu="$2"
  local ram="$3"
  local mac_suffix="$4"
  local ip=$5
  # optional params
  local ip_ext=$6

  local params=""
  if [[ -n "$ip_ext" ]] ; then
    params="$params --network network=$nname_ext,model=$net_driver,mac=$mac_base_ext:$mac_suffix"
  fi

  echo "INFO: running machine $name $(date)"
  cp $BASE_IMAGE $pool_path/$name.qcow2
  virt-install --name $name \
    --ram $ram \
    --vcpus $cpu \
    --virt-type kvm \
    --os-type=linux \
    --os-variant ubuntu16.04 \
    --disk path=$pool_path/$name.qcow2,cache=writeback,bus=virtio,serial=$(uuidgen) \
    --noautoconsole \
    --graphics vnc,listen=0.0.0.0 \
    --network network=$nname,model=$net_driver,mac=$mac_base:$mac_suffix \
    --cpu SandyBridge,+vmx,+ssse3 \
    --boot hd \
    $params \
    --dry-run --print-xml > /tmp/oc-$name.xml
  virsh define --file /tmp/oc-$name.xml
  virsh net-update $nname add ip-dhcp-host "<host mac='$mac_base:$mac_suffix' name='$name' ip='$ip' />"
  if [[ -n "$ip_ext" ]] ; then
    virsh net-update $nname_ext add ip-dhcp-host "<host mac='$mac_base_ext:$mac_suffix' name='$name' ip='$ip_ext' />"
  fi
  virsh start $name --force-boot
  echo "INFO: machine $name run $(date)"
}

wait_cmd="ssh"
function wait_kvm_machine() {
  local ip=$1
  local iter=0
  sleep 10
  while ! $wait_cmd $image_user@$ip "uname -a" &>/dev/null ; do
    ((++iter))
    if (( iter > 9 )) ; then
      echo "ERROR: machine $ip is not accessible $(date)"
      exit 2
    fi
    sleep 10
  done
}

cont_ip="$addr.$cont_idx"
run_machine ${job_prefix}-cont 1 2048 $cont_idx $cont_ip
wait_kvm_machine $cont_ip

echo "INFO: bootstraping juju controller $(date)"
juju bootstrap manual/$image_user@$cont_ip $juju_controller_name

declare -A machines

function run_cloud_machine() {
  local name=$1
  local mac_suffix=$2
  local mem=$3
  local ip=$4

  local ip="$addr.$mac_suffix"
  run_machine ${job_prefix}-os-$name 4 $mem $mac_suffix $ip "$addr_ext.$mac_suffix"
  echo "INFO: start machine $name waiting $name $(date)"
  wait_kvm_machine $ip
  echo "INFO: adding machine $name to juju controller $(date)"
  juju-add-machine ssh:$image_user@$ip
  mch=`get_machine_by_ip $ip`
  echo "INFO: machine $name (machine: $mch) is ready $(date)"
  machines["$name"]=$mch
}

function run_compute() {
  local index=$1
  local mac_var_name="os_comp_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating compute $index (mac suffix $mac_suffix) $(date)"
  local ip="$addr.$mac_suffix"
  run_cloud_machine comp-$index $mac_suffix 4096 $ip
  mch=`get_machine_by_ip $ip`

  echo "INFO: preparing compute $index $(date)"
  juju-ssh $mch "sudo apt-get -fy install mc wget openvswitch-switch" &>>$log_dir/apt.log
  juju-scp "$my_dir/files/50-cloud-init-compute-xenial.cfg" $mch:50-cloud-init.cfg 2>/dev/null
  juju-ssh $mch "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null
  juju-ssh $mch "echo 'supersede routers $addr.1;' | sudo tee -a /etc/dhcp/dhclient.conf"
  juju-ssh $mch "sudo reboot" 2>/dev/null || /bin/true
  wait_kvm_machine $ip
}

function run_network() {
  local index=$1
  local mac_var_name="os_net_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating network $index (mac suffix $mac_suffix) $(date)"
  local ip="$addr.$mac_suffix"
  run_cloud_machine net-$index $mac_suffix 4096 $ip
  mch=`get_machine_by_ip $ip`

  echo "INFO: preparing network $index $(date)"
  juju-ssh $mch "sudo apt-get -fy install mc wget openvswitch-switch" &>>$log_dir/apt.log
  juju-scp "$my_dir/files/50-cloud-init-compute-xenial.cfg" $mch:50-cloud-init.cfg 2>/dev/null
  juju-ssh $mch "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null
  juju-ssh $mch "echo 'supersede routers $addr.1;' | sudo tee -a /etc/dhcp/dhclient.conf"
  juju-ssh $mch "sudo reboot" 2>/dev/null || /bin/true
  wait_kvm_machine $ip
}

function run_controller() {
  local index=$1
  local mem=$2
  local prepare_for_openstack=$3
  local mac_var_name="os_cont_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating controller $index (mac suffix $mac_suffix) $(date)"
  local ip="$addr.$mac_suffix"
  run_cloud_machine cont-$index $mac_suffix $mem $ip
  mch=`get_machine_by_ip $ip`

  echo "INFO: preparing controller $index $(date)"
  juju-ssh $mch "sudo apt-get -fy install mc wget bridge-utils" &>>$log_dir/apt.log
  if [[ "$prepare_for_openstack" == '1' ]]; then
    juju-ssh $mch "sudo sed -i -e 's/^USE_LXD_BRIDGE.*$/USE_LXD_BRIDGE=\"false\"/m' /etc/default/lxd-bridge" 2>/dev/null
    juju-ssh $mch "sudo sed -i -e 's/^LXD_BRIDGE.*$/LXD_BRIDGE=\"br-$IF1\"/m' /etc/default/lxd-bridge" 2>/dev/null
  fi
  juju-scp "$my_dir/files/50-cloud-init-controller-xenial.cfg" $mch:50-cloud-init.cfg 2>/dev/null
  juju-ssh $mch "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null
  juju-ssh $mch "echo 'supersede routers $addr.1;' | sudo tee -a /etc/dhcp/dhclient.conf"
  juju-ssh $mch "sudo reboot" 2>/dev/null || /bin/true
  wait_kvm_machine $ip
}

run_controller 0 8192 1

run_compute 1
run_compute 2

run_network 1
run_network 2
run_network 3

wait_for_all_machines

echo "INFO: creating hosts file $(date)"
truncate -s 0 $WORKSPACE/hosts
for m in ${!machines[@]} ; do
  echo "${machines[$m]}    $m" >> $WORKSPACE/hosts
done
cat $WORKSPACE/hosts
echo "INFO: Applying hosts file and hostnames $(date)"
for m in ${!machines[@]} ; do
  mch=${machines[$m]}
  echo "INFO: Apply $m for $ip"
  juju-scp $WORKSPACE/hosts $mch:hosts
  juju-ssh $mch "sudo bash -c 'echo $m > /etc/hostname ; hostname $m'" 2>/dev/null
  juju-ssh $mch 'sudo bash -c "cat ./hosts >> /etc/hosts"' 2>/dev/null
done
rm $WORKSPACE/hosts

echo "INFO: Environment created $(date)"

virsh net-dhcp-leases $nname

trap - ERR EXIT
