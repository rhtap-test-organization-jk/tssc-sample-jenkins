#!/bin/bash

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )" 

# buildah-rhtap
source $SCRIPTDIR/common.sh 



function build() {
	echo "Running $TASK_NAME:build"
	echo "Running Login"
	IMAGE_REGISTRY="${IMAGE%%/*}"
	buildah login -u $QUAY_IO_CREDS_USR -p $QUAY_IO_CREDS_PSW $IMAGE_REGISTRY
	ERR=$? 
	if [ $ERR != 0 ]; then
		echo "Failed login $IMAGE_REGISTRY for user $QUAY_IO_CREDS_USR " 
		exit $ERR
	fi
	echo "Mirror buildah login info into ~/.docker/config.json for cosign"
	echo "cat ${XDG_RUNTIME_DIR}/containers/auth.json > ~/.docker/config.json" 
 	#cat /run/containers/0/containers/auth.json > ~/.docker/config.json
  	echo /run/user/0/containers/auth.json > ~/.docker/config.json
	# cat ${XDG_RUNTIME_DIR}/containers/auth.json > ~/.docker/config.json

	# Check if the Dockerfile exists
	SOURCE_CODE_DIR=.
	if [ -e "$SOURCE_CODE_DIR/$CONTEXT/$DOCKERFILE" ]; then
	  dockerfile_path="$SOURCE_CODE_DIR/$CONTEXT/$DOCKERFILE"
	elif [ -e "$SOURCE_CODE_DIR/$DOCKERFILE" ]; then
	  dockerfile_path="$SOURCE_CODE_DIR/$DOCKERFILE"
	else
	  echo "Cannot find Dockerfile $DOCKERFILE"
	  exit 1
	fi
	
	BUILDAH_ARGS=()
	if [ -n "${BUILD_ARGS_FILE}" ]; then
	  BUILDAH_ARGS+=("--build-arg-file=${SOURCE_CODE_DIR}/${BUILD_ARGS_FILE}")
	fi
	
	for build_arg in "$@"; do
	  BUILDAH_ARGS+=("--build-arg=$build_arg")
	done
	
	# Build the image
	buildah build \
	  "${BUILDAH_ARGS[@]}" \
	  --tls-verify=$TLSVERIFY \
	  --ulimit nofile=4096:4096 \
	  -f "$dockerfile_path" -t $IMAGE $SOURCE_CODE_DIR/$CONTEXT
	
	# Push the image
	buildah push \
	  --tls-verify=$TLSVERIFY \
	  --retry=5 \
	  --digestfile $TEMP_DIR/files/image-digest $IMAGE \
	  docker://$IMAGE
	
	# Set task results
	buildah images --format '{{ .Name }}:{{ .Tag }}@{{ .Digest }}' | grep -v $IMAGE > $RESULTS/BASE_IMAGES_DIGESTS
	cat $TEMP_DIR/files/image-digest | tee $RESULTS/IMAGE_DIGEST
	echo -n "$IMAGE" | tee $RESULTS/IMAGE_URL
	
	# Save the image so it can be used in the generate-sbom step
	buildah push "$IMAGE" oci:$TEMP_DIR/files/image
	 
}

function generate-sboms() {
	echo "Running $TASK_NAME:generate-sboms"
	syft dir:. --output cyclonedx-json@1.5=$TEMP_DIR/files/sbom-source.json
	syft oci-dir:$TEMP_DIR/files/image --output cyclonedx-json@1.5=$TEMP_DIR/files/sbom-image.json
}

function upload-sbom() {
	echo "Running $TASK_NAME:upload-sbom" 
	cosign attach sbom --sbom $TEMP_DIR/files/sbom-cyclonedx.json --type cyclonedx "$IMAGE"
}
function delim() { 
	printf '=%.0s' {1..8}
}
# Task Steps 
build
delim
generate-sboms
delim
echo "RUNNING PYTHON "
python3 $SCRIPTDIR/merge-sboms.sh
# check error from python
ERR=$? 
if [ $ERR != 0 ]; then
	echo "Failed in step merge-sboms.sh" 
	exit $ERR
fi

delim
upload-sbom
delim

exit_with_success_result
