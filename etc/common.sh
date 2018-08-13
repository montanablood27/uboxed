#!/bin/bash
# Shared variables and functions


#--- Global Settings ---#
# Host network parameters
export HOSTNAME=`hostname --fqdn`
export HTTP_PORT=80
export HTTPS_PORT=443
export SWAN_HTTPS_PORT=8443
export WEBDAV_CLIENT_CERT_PORT=4443

# Temporary work folder on the host
export HOST_FOLDER="/tmp/sciencebox"
export EOS_FOLDER=$HOST_FOLDER"/eos_mount"
export CVMFS_FOLDER=$HOST_FOLDER"/cvmfs_mount"
export CERTS_FOLDER=$HOST_FOLDER"/certs"
WARNING_FILE=$HOST_FOLDER"/DO_NOT_WRITE_ANY_FILE_HERE"

# Single-user notebook image
export NOTEBOOK_IMAGE="cernphsft/systemuser:v2.11"

# Docker network
export DOCKER_NETWORK_NAME="demonet"

# Docker volumes
export LDAP_DB="ldap_database"
export LDAP_CF="ldap_config"

export EOS_MGM="eos-mgm"
export EOS_MQ="eos-mq"
for i in {1..4}
do
  export EOS_FST_$i="eos-fst_"$i
  export EOS_FST_USERDATA_$i="eos-fst_userdata_"$i
done

export CERNBOX_DB="cernbox_shares_db"




# Software version
#TODO: Pin Docker version
export DOCKERCOMPOSE_VERSION="1.15.0"   # Since 2017-08-08


# Docker images
# TODO: From here on

# Images to be pulled
NOTEBOOK_IMAGES=(cernphsft/systemuser:v2.10) # , jupyter/minimal-notebook)

#SYS_IMAGES=(cernbox cernboxgateway eos-controller eos-storage ldap swan_cvmfs swan_eos-fuse swan_jupyterhub)
# Deprecated since the introduction of Images for Kubernetes
SYSIM_PRIVATE=false
SYSIM_REPO="gitlab-registry.cern.ch/cernbox/boxedhub"
SYS_IMAGES=(gitlab-registry.cern.ch/cernbox/boxedhub/ldap:v0 \
gitlab-registry.cern.ch/cernbox/boxedhub/eos-controller:latest \
gitlab-registry.cern.ch/cernbox/boxedhub/eos-storage:v0 \
gitlab-registry.cern.ch/cernbox/boxedhub/cernbox:v0 \
gitlab-registry.cern.ch/cernbox/boxedhub/cernboxgateway:v0 \
gitlab-registry.cern.ch/cernbox/boxedhub/jupyterhub:v0 \
gitlab-registry.cern.ch/cernbox/boxedhub/cvmfs:v0 \
gitlab-registry.cern.ch/cernbox/boxedhub/eos-fuse:v0 )

### EOS
#TODO: This is not used for the moment
EOS_SUPPORTED_VERSIONS=(AQUAMARINE CITRINE)
EOS_CODENAME="AQUAMARINE"	# Pick one among EOS_SUPPORTED_VERSIONS



# ----- Functions ----- #
# Check to be root
function need_root {
if [ "$EUID" -ne 0 ]; then
	echo "Please run as root"
	exit 1
fi
}

# Print a warning about the required software on the host
function warn_about_software_requirements {
echo ""
echo "The following software has to be installed:"
echo -e "\t- wget"
echo -e "\t- fuse"
echo -e "\t- git"
echo -e "\t- docker (version 17.03.1-ce or greater)"
echo -e "\t- docker-compose (version 1.11.2 or greater)"
echo ""
echo "Please consider installing it manually or using the script SetupInstall-<YourOS>.sh."
echo ""
}

# Wait for some time so that the user reads
function wait_for_user_read {
WAIT_FOR_USER_READ=10
while [ $WAIT_FOR_USER_READ -gt 0 ]; do
	echo -ne "\r$WAIT_FOR_USER_READ...\033[0K"
	sleep 1
	WAIT_FOR_USER_READ=$((WAIT_FOR_USER_READ-1))
done
echo "Continuing..."
}

# Print a warning about potential interference with EOS || CVMFS processes running on the host
function warn_about_interfence_eos_cvmfs {
echo ""
echo "WARNING: The deployment interferes with eventual CVMFS and EOS clients running on the host."
echo "All the running clients will be killed before proceeding."
read -r -p "Do you want to continue [y/N] " response
case "$response" in
    [yY])
        echo "Ok."
        ;;
    *)
        echo "Cannot continue. Exiting..."
        echo ""
        exit 1
        ;;
esac
}


# CLEANUP
# Warn about eventual single user's servers running
function check_single_user_container_running {
RUNNING_CONTAINERS=`docker ps -a | tail -n+2 | awk '{print $NF}' | grep '^jupyter-' | tr '\n' ' '`

if [[ -z $RUNNING_CONTAINERS ]];
then
	return 0
else
	echo ""
	echo "WARNING: The following SWAN user's servers are in execution"
        for i in $RUNNING_CONTAINERS; do echo "  - $i"; done

	echo ""
	if  [[ "$1" == "start" ]]; then
	        echo "Please consider that their normal operation might be interrupted or that they might prevent some services to restart."
	elif [[ "$1" == "stop" ]]; then
	        echo "Please consider that their normal operation will be interrupted."
	fi
        echo "It is recommended to stop user's servers before proceeding."
	read -r -p "Do you want to continue anyway [y/N] " response
	case "$response" in
	  [yY])
		echo "Ok."
		return 0
		;;
	  *)
		echo "Cannot continue. Exiting..."
		echo ""
		exit 1
		;;
	esac
fi
}

# Remove old containers
function stop_and_remove_containers {
# WARNING: This is not going to work in case a single-user server is still running, e.g., jupyter-userN
#          Single-user's servers keep CVMFS and EOS locked due to internal mount

echo ""
echo "Removing existing containers (if any)..."
# Stop the containers managed by docker-compose (and remove dangling volumes)
if [ -z $1 ]; then
	docker-compose down -v
else
	docker-compose -f $1 down -v
fi
#docker stop jupyterhub ldap ldap-ldapadd cvmfs eos-fuse cernbox cernboxgateway 2>/dev/null
#docker rm -f jupyterhub ldap ldap-ldapadd cvmfs eos-fuse cernbox cernboxgateway 2>/dev/null

# NOTE: Containers for EOS storage are not managed by docker-compose
#       They need to be stopped and removed manually
docker stop eos-fst{1..6} eos-mq eos-mgm 2>/dev/null
docker rm -f eos-fst{1..6} eos-mq eos-mgm eos-controller 2>/dev/null
}

# Remove folders with EOS || CVMFS fuse mount on the host
function cleanup_folders_for_fusemount {
echo ""
echo "Cleaning up folders..."
killall cvmfs2 2>/dev/null
killall eos 2>/dev/null
sleep 1

if [[ -d $HOST_FOLDER ]];
then
	# Unmount and remove CVMFS
	for i in `ls $CVMFS_FOLDER`
	do
	        fusermount -u $CVMFS_FOLDER/$i
	        rmdir $CVMFS_FOLDER/$i
	done
	fusermount -u $CVMFS_FOLDER
	rmdir $CVMFS_FOLDER

	# Unmount and remove EOS
	while [[ ! -z `mount -l | grep $EOS_FOLDER | head -n 1` ]];
	do
	        fusermount -u $EOS_FOLDER
	done
	rmdir $EOS_FOLDER

	# Remove certificates (making sure to have the folder first)
	if [ -d "$CERTS_FOLDER" ]; then
		rm "$CERTS_FOLDER"/boxed.key
	        rm "$CERTS_FOLDER"/boxed.crt 
	        rmdir $CERTS_FOLDER
	fi

	# Remove the warning file
	rm $WARNING_FILE

	# Remove the entire directory
	rmdir $HOST_FOLDER
fi
}

# Remove docker network
function docker_network_remove {
echo ""
echo "Removing Docker network $DOCKER_NETWORK_NAME"

# Check the network exists
docker network inspect $DOCKER_NETWORK_NAME > /dev/null 2>&1
if [[ "$?" -gt "0" ]]; then
	echo "Docker network $DOCKER_NETWORK_NAME does not exist."
	return 0
else
	# If exists, check for connected containers
	docker network inspect $DOCKER_NETWORK_NAME | grep "\"Containers\": {}" >/dev/null 2>&1
	if [[ "$?" -gt 0 ]]; then
	        echo "Cannot remove Docker network $DOCKER_NETWORK_NAME"
	        echo "Some containers are still connected to it."
	        docker network inspect $DOCKER_NETWORK_NAME
        	return 1
	else
		# If exists and no connected containers, remove it!
	        docker network remove $DOCKER_NETWORK_NAME
		return 0
	fi
fi
}


# Re-initialize folders with EOS || CVMFS fuse mount 
function initialize_folders_for_fusemount {
echo ""
echo "Initializing folders..."
mkdir -p $HOST_FOLDER
touch $WARNING_FILE

# Explicitly set CVMFS and EOS folders as shared
for i in $CVMFS_FOLDER $EOS_FOLDER
do
	mkdir -p $i
	mount --bind $i $i
	mount --make-shared $i
done
}

# Check if you have certificates for replacing the default ones in Docker images
function check_override_certificates {
echo ""
echo "Checking the availability of new certificates for HTTPS..."
if [[ -f "$RUN_FOLDER"/certs/boxed.crt && -f "$RUN_FOLDER"/certs/boxed.key ]]; then
	return 0
fi
return 1
}

# (Eventually) Copy the available certificates for HTTPS in the temporary folder
function copy_override_certificates {
echo "Copying new certificates for HTTPS..."
mkdir -p $CERTS_FOLDER
cp "$RUN_FOLDER"/certs/boxed.crt "$CERTS_FOLDER"/boxed.crt
cp "$RUN_FOLDER"/certs/boxed.key "$CERTS_FOLDER"/boxed.key
}


# PULL DOCKER IMAGES
# Single-user Jupyter Server
function fetch_singleuser_notebook_image {
# See: https://github.com/cernphsft/systemuser
echo ""
echo "Pulling Single-User notebook image..."
for i in ${NOTEBOOK_IMAGES[*]};
do
        docker pull $i
done
}

# All the other system components
function fetch_system_component_images {
echo ""
echo "Pulling system component images..."

if [ `echo $SYSIM_PRIVATE | tr '[:upper:]' '[:lower:]'` = "true" ]; then
	echo "Log in to remote repository"
	docker login $SYSIM_LOGIN
fi

for i in ${SYS_IMAGES[*]};
do
	docker pull $i
done
#for i in ${SYS_IMAGES[*]};
#do
#        docker pull "$SYSIM_REPO":"$i"
#        docker tag "$SYSIM_REPO":"$i" "$i":latest
#	docker rmi "$SYSIM_REPO":"$i"
#done
}

# Check to have fetched all the images
function check_to_have_images {
# Contrast two arrays checking that all elements of the first appear in the second one
# Input: $1==required_images (as array)   $2==available_images (as array)
        declare -a required=("${!1}")
        declare -a available=("${!2}")

        for req in "${required[@]}";
        do
                found=0
                for ava in "${available[@]}";
                do
                        if [[ "$req" == "$ava" ]];
                        then
                                found=1
                                break
                        fi
                done
                if [[ "$found" -eq "0" ]];
                then
                        echo  "Unable to find $req image locally. Cannot continue."
                        exit 1
                fi
        done
}

function check_to_have_all_images {
        echo ""
        echo "Check to have all the required images..."
        # Check to have system component images
        #LOCAL_IMAGES=`docker image ls | tail -n+2 | awk '{print $1}' | sort | tr '\n' ' '`
        read -r -a LOCAL_IMAGES <<< `docker image ls | tail -n+2 | awk '{print $1":"$2}' | tr '\n' ' '`
        check_to_have_images SYS_IMAGES[@] LOCAL_IMAGES[@]

        # Check to have single user notebook images -- tag column is part of the check
        #LOCAL_IMAGES=`docker image ls | tail -n+2 | awk '{print $1":"$2}' | tr '\n' ' '`
        read -r -a LOCAL_IMAGES <<< `docker image ls | tail -n+2 | awk '{print $1":"$2}' | tr '\n' ' '`
        check_to_have_images NOTEBOOK_IMAGES[@] LOCAL_IMAGES[@]
        echo "Ok."
}

function check_ports_availability {
	echo ""
	echo "Check availability of ports $HTTP_PORT and $HTTPS_PORT..."
	netstat -ltnp | grep "tcp" | grep -v "^tcp6" | while read -r line; 
	do
	        port_no=`echo $line | tr -s ' ' | cut -d ' ' -f 4 | cut -d ':' -f 2`
	        process=`echo $line | tr -s ' ' | cut -d ' ' -f 7-`

	        if [[ "$port_no" -eq "$HTTP_PORT" || "$port_no" -eq "$HTTPS_PORT" ]];
	        then 
	                echo "Port $port_no is being used by process $process. Cannot continue."
	                echo "Please stop the process or set another port in etc/common.sh"
	                exit 1
	        fi
	done
	[[ $? != 0 ]] && exit $?
	echo "Ok."
}


# DOCKER DEPLOYMENT
function check_required_services_are_available {
# Check docker daemon in running state
	# TODO: Would be preferrable to use the exit code of `service docker status`, 
	#	but it always returns 0 on Ubuntu 14.04
if [ "`pgrep docker`" == "" ]; then
	echo "Docker daemon is not running. Cannot continue."
	exit 1
fi

# Check docker-compose is available and returns something when asking for version
if [ ! -f /usr/local/bin/docker-compose ] || [ "`docker-compose --version`" == "" ]; then
	echo "Docker-compose is not available. Cannot continue."
	exit 1
fi

echo "All required services are available."
}

# Check to have (or create) a Docker network to allow communications among containers
function docker_network {
echo ""
echo "Setting up Docker network..."
docker network inspect $DOCKER_NETWORK_NAME >/dev/null 2>&1 || docker network create $DOCKER_NETWORK_NAME
docker network inspect $DOCKER_NETWORK_NAME
}

# Initialize volumes for EOS --> Make storage persistent
function volumes_for_eos {
echo ""
echo "Initialize Docker volumes for EOS..."
docker volume inspect $EOS_MQ >/dev/null 2>&1 || docker volume create --name $EOS_MQ
docker volume inspect $EOS_MGM >/dev/null 2>&1 || docker volume create --name $EOS_MGM
for i in {1..4}
do
    metadata_volume=EOS_FST_"$i"
    docker volume inspect ${!metadata_volume} >/dev/null 2>&1 || docker volume create --name ${!metadata_volume}
    userdata_volume=EOS_FST_USERDATA_"$i"
    docker volume inspect ${!userdata_volume} >/dev/null 2>&1 || docker volume create --name ${!userdata_volume}
done
}

# Initialize volumes for LDAP
function volumes_for_ldap {
echo ""
echo "Initialize Docker volume for LDAP..."
docker volume inspect $LDAP_DB >/dev/null 2>&1 || docker volume create --name $LDAP_DB
docker volume inspect $LDAP_CF >/dev/null 2>&1 || docker volume create --name $LDAP_CF
}

# Initialize volumes from CERNBox --> Make sharing settings persistent
function volumes_for_cernbox {
echo ""
echo "Initialize Docker volume for CERNBox..."
docker volume inspect $CERNBOX_DB >/dev/null 2>&1 || docker volume create --name $CERNBOX_DB
}

# Create Environment file with variables defined above
function create_env_file {
echo ""
echo "Creating environment file..."
envsubst < env.template > .env
}

# Set locks to control dependencies and execution order
function set_the_locks {
echo ""
echo "Setting up locks..."
echo "Locking EOS-MGM -- Needs LDAP"
touch "$HOST_FOLDER"/eos-mgm-lock
echo "Locking EOS-FSTs -- Need EOS-MGM"
touch "$HOST_FOLDER"/eos-fst-lock
echo "Locking eos-fuse client -- Needs EOS storage"
touch "$HOST_FOLDER"/eos-fuse-lock
echo "Locking cernbox -- Needs EOS storage"
touch "$HOST_FOLDER"/cernbox-lock
echo "Locking cernboxgateway -- Needs EOS storage"
touch "$HOST_FOLDER"/cernboxgateway-lock

touch "$HOST_FOLDER"/usercontrol-lock
}

