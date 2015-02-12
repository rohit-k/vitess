## Script that installs, configures and tests Vitess on a single node

## Most vtctlclient commands produce no output on success, so check status
# of the command
check_error(){
    if [[ $? -ne 0 ]] ; then
        echo "$*"
    fi
}

## Check if logged is a non-root user
if [[ $EUID -eq 0 ]]; then
   echo "This script must not be run as root" 
   exit 1
fi

# Source proxy configuration, if exists, useful in a data center env
if [[ -e ~/proxyrc ]]; then
    source ~/proxyrc
fi

##### Install Dependencies #####
#1. MariaDB 10.0.14 #
sudo -E apt-get -yes --force-yes install software-properties-common
sudo -E apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xcbcb082a1bb943db
sudo -E add-apt-repository 'deb http://mariadb.bytenet.in//repo/10.0/ubuntu trusty main'
sudo -E apt-get update
sudo -E apt-get -yes --force-yes install mariadb-server libmariadbclient-dev

#2. GO - Install golang 1.3+. The apt-get repositories for 14.04 contain
# golang 1.2.1. Hence, install from source

# Download the latest distro
curl -O https://storage.googleapis.com/golang/go1.4.1.linux-amd64.tar.gz

# Unpack it to /usr/local
sudo tar -C /usr/local -xzf go1.4.1.linux-amd64.tar.gz

# Set GOPATH and PATH
mkdir -p ~/go; echo "export GOPATH=$HOME/go" >> ~/.bashrc

# Update path
echo "export PATH=$PATH:$HOME/go/bin:/usr/local/go/bin" >> ~/.bashrc

# Read the environment variables into the current session
source ~/.bashrc

#3. Install the rest of the stuff
sudo -E apt-get install --yes --force-yes openjdk-7-jre make automake libtool memcached python-dev python-mysqldb libssl-dev g++ mercurial git pkg-config bison curl

##### Clone, Bootstrap, Build Vitess #####
git clone https://github.com/youtube/vitess.git src/github.com/youtube/vitess
cd src/github.com/youtube/vitess
export MYSQL_FLAVOR=MariaDB
./bootstrap.sh
. ./dev.env
make build

# Run some light tests
make site_test

##### Set up a Local Vitess Cluster as explained in
# https://github.com/youtube/vitess/tree/master/examples/local
#####

# Start Zookeper
cd $VTROOT/src/github.com/youtube/vitess/examples/local
./zk-up.sh
export ZK_CLIENT_CONFIG=$VTROOT/src/github.com/youtube/vitess/examples/local/zk-client-conf.json

# Start vtctld - This starts up the vtctld server and provides the web interface on localhost:15000
msg="Error! Could not start vtctld server. Exiting.."
./vtctld-up.sh
check_error $msg

# Test a vtctlclient command to administer the cluster
msg="Error! vtctld server not running. Exiting.."
$VTROOT/bin/vtctlclient --server localhost:15000 GetVSchema
check_error $msg

# Start 3 vttablets
msg="Error! Could not start vttablets. Exiting.."
./vttablet-up.sh
check_error $msg

# Perform a keyspace rebuild to initialize the keyspace for the new shard
msg="Error! Keyspace Rebuild failed. Exiting.."
$VTROOT/bin/vtctlclient -server localhost:15000 RebuildKeyspaceGraph test_keyspace
check_error $msg

# Elect a master Vttablet, after which 1 master and 2 replicas can be seen
msg="Error! Vttablet Master election failed. Exiting.."
$VTROOT/bin/vtctlclient --server localhost:15000 ReparentShard -force test_keyspace/0 test-0000000100
check_error $msg

# List all the tablets
$VTROOT/bin/vtctlclient --server localhost:15000 ListAllTablets test

# Create a table
msg="Error! Could not create a test table. Exiting.."
$VTROOT/bin/vtctlclient -server localhost:15000 ApplySchemaKeyspace -simple -sql "$(cat create_test_table.sql)" test_keyspace
check_error $msg

# Start vtgate
msg="Error! Could not start vtgate. Exiting.."
./vtgate-up.sh
check_error $msg

# Run wrapper script for client access to connect to vtgate and run queries
msg="Error! Client app failed. Exiting.."
./client.sh --server=localhost:15001
check_error $msg
