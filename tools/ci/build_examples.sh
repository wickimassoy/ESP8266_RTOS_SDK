#!/bin/bash
#
# Build all examples from the examples directory, out of tree to
# ensure they can run when copied to a new directory.
#
# Runs as part of CI process.
#
# Assumes PWD is an out-of-tree build directory, and will copy examples
# to individual subdirectories, one by one.
#
#
# Without arguments it just builds all examples
#
# With one argument <JOB_NAME> it builds part of the examples. This is a useful for
#   parallel execution in CI.
#   <JOB_NAME> must look like this:
#               <some_text_label>_<num>
#   It scans .gitlab-ci.yaml to count number of jobs which have name "<some_text_label>_<num>"
#   It scans the filesystem to count all examples
#   Based on this, it decides to run qa set of examples.
#

# -----------------------------------------------------------------------------
# Safety settings (see https://gist.github.com/ilg-ul/383869cbb01f61a51c4d).

if [[ ! -z ${DEBUG_SHELL} ]]
then
  set -x # Activate the expand mode if DEBUG is anything but empty.
fi

set -o errexit # Exit if command failed.
set -o pipefail # Exit if pipe failed.
set -o nounset # Exit if variable not set.

# Remove the initial space and instead use '\n'.
IFS=$'\n\t'

# -----------------------------------------------------------------------------

die() {
    echo "${1:-"Unknown Error"}" 1>&2
    exit 1
}

[ -z ${IDF_PATH} ] && die "IDF_PATH is not set"
[ -z ${LOG_PATH} ] && die "LOG_PATH is not set"
[ -d ${LOG_PATH} ] || mkdir -p ${LOG_PATH}

echo "build_examples running in ${PWD}"

# only 0 or 1 arguments
[ $# -le 1 ] || die "Have to run as $(basename $0) [<JOB_NAME>]"

export BATCH_BUILD=1
export V=0 # only build verbose if there's an error

export IDF_CI_BUILD=1

export EXAMPLE_MQTT_BROKER_CERTIFICATE="https://www.espressif.com/"
export EXAMPLE_MQTT_BROKER_WS="https://www.espressif.com/"
export EXAMPLE_MQTT_BROKER_WSS="https://www.espressif.com/"
export EXAMPLE_MQTT_BROKER_SSL="https://www.espressif.com/"
export EXAMPLE_MQTT_BROKER_TCP="https://www.espressif.com/"

shopt -s lastpipe # Workaround for Bash to use variables in loops (http://mywiki.wooledge.org/BashFAQ/024)

RESULT=0
FAILED_EXAMPLES=""
RESULT_ISSUES=22  # magic number result code for issues found
LOG_SUSPECTED=${LOG_PATH}/common_log.txt
touch ${LOG_SUSPECTED}
SDKCONFIG_DEFAULTS_CI=sdkconfig.ci

if [ $# -eq 0 ]
then
    START_NUM=0
    END_NUM=999
else
    JOB_NAME=$1

    # parse text prefix at the beginning of string 'some_your_text_NUM'
    # (will be 'some_your_text' without last '_')
    JOB_PATTERN=$( echo ${JOB_NAME} | sed -n -r 's/^(.*)_[0-9]+$/\1/p' )
    [ -z ${JOB_PATTERN} ] && die "JOB_PATTERN is bad"

    # parse number 'NUM' at the end of string 'some_your_text_NUM'
    # NOTE: Getting rid of the leading zero to get the decimal
    JOB_NUM=$( echo ${JOB_NAME} | sed -n -r 's/^.*_0*([0-9]+)$/\1/p' )
    [ -z ${JOB_NUM} ] && die "JOB_NUM is bad"

    # count number of the jobs
    NUM_OF_JOBS=$( grep -c -E "^${JOB_PATTERN}_[0-9]+:$" "${IDF_PATH}/.gitlab-ci.yml" )
    [ -z ${NUM_OF_JOBS} ] && die "NUM_OF_JOBS is bad"

    # count number of examples
    NUM_OF_EXAMPLES=$( find ${IDF_PATH}/examples/ -type f -name Makefile | wc -l )
    [ -z ${NUM_OF_EXAMPLES} ] && die "NUM_OF_EXAMPLES is bad"

    # separate intervals
    #57 / 5 == 12
    NUM_OF_EX_PER_JOB=$(( (${NUM_OF_EXAMPLES} + ${NUM_OF_JOBS} - 1) / ${NUM_OF_JOBS} ))
    [ -z ${NUM_OF_EX_PER_JOB} ] && die "NUM_OF_EX_PER_JOB is bad"

    # ex.: [0; 12); [12; 24); [24; 36); [36; 48); [48; 60)
    START_NUM=$(( ${JOB_NUM} * ${NUM_OF_EX_PER_JOB} ))
    [ -z ${START_NUM} ] && die "START_NUM is bad"

    END_NUM=$(( (${JOB_NUM} + 1) * ${NUM_OF_EX_PER_JOB} ))
    [ -z ${END_NUM} ] && die "END_NUM is bad"
fi

build_example () {
    local ID=$1
    shift
    local MAKE_FILE=$1
    shift

    local EXAMPLE_DIR=$(dirname "${MAKE_FILE}")
    local EXAMPLE_NAME=$(basename "${EXAMPLE_DIR}")

    local EXAMPLE_BUILD_DIRS=()

    # count number of CI sdkconfig files
    SDKCONFIG_CI_FILES=$( find ${EXAMPLE_DIR}/ -type f -name sdkconfig.ci.* | sort )
    if [[ -z ${SDKCONFIG_CI_FILES} ]]; then
        EXAMPLE_BUILD_DIRS[0]="${ID}_${EXAMPLE_NAME}"
    else
        COUNT=0
        for CI_FILE in ${SDKCONFIG_CI_FILES}
        do
            EXAMPLE_BUILD_DIRS[COUNT]="${ID}_${EXAMPLE_NAME}_${CI_FILE##*.}"
            COUNT=$(( $COUNT + 1 ))
        done
    fi
    
    for EXAMPLE_BUILD_DIR in ${EXAMPLE_BUILD_DIRS[*]}
    do
        if [[ -f "example_builds/${EXAMPLE_BUILD_DIR}/build/ci_build_success" ]]; then
            echo "Project ${EXAMPLE_BUILD_DIR} has been built and skip building ..."
        else
            echo "Building ${EXAMPLE_BUILD_DIR}..."
            mkdir -p "example_builds/${EXAMPLE_BUILD_DIR}"
            cp -r "${EXAMPLE_DIR}/"* "example_builds/${EXAMPLE_BUILD_DIR}/"

            if [[ -n ${SDKCONFIG_CI_FILES} ]]; then
                cp "example_builds/${EXAMPLE_BUILD_DIR}/sdkconfig.ci.${EXAMPLE_BUILD_DIR##*_}" "example_builds/${EXAMPLE_BUILD_DIR}/sdkconfig.ci"
                rm example_builds/${EXAMPLE_BUILD_DIR}/sdkconfig.ci.*
            fi
        
            pushd "example_builds/${EXAMPLE_BUILD_DIR}"
                # be stricter in the CI build than the default IDF settings
                export EXTRA_CFLAGS="-Werror -Werror=deprecated-declarations"
                export EXTRA_CXXFLAGS=${EXTRA_CFLAGS}

                # sdkconfig files are normally not checked into git, but may be present when
                # a developer runs this script locally
                rm -f sdkconfig

                # If sdkconfig.ci file is present, append it to sdkconfig.defaults,
                # replacing environment variables
                if [[ -f "$SDKCONFIG_DEFAULTS_CI" ]]; then
                    cat $SDKCONFIG_DEFAULTS_CI | $IDF_PATH/tools/ci/envsubst.py >> sdkconfig.defaults
                fi

                # build non-verbose first
                local BUILDLOG=${LOG_PATH}/ex_${EXAMPLE_BUILD_DIR}_log.txt
                touch ${BUILDLOG}

                local FLASH_ARGS=build/download.config

                make clean >>${BUILDLOG} 2>&1 &&
                make defconfig >>${BUILDLOG} 2>&1 &&
                make all -j4 >>${BUILDLOG} 2>&1 &&
                make ota >>${BUILDLOG} 2>&1 &&
                make print_flash_cmd >${FLASH_ARGS}.full 2>>${BUILDLOG} &&
                touch build/ci_build_success ||
                {
                    RESULT=$?; FAILED_EXAMPLES+=" ${EXAMPLE_NAME}" ;
                }

                tail -n 1 ${FLASH_ARGS}.full > ${FLASH_ARGS} || :
                test -s ${FLASH_ARGS} || die "Error: ${FLASH_ARGS} file is empty"

                cat ${BUILDLOG}
            popd

            grep -i "error\|warning" "${BUILDLOG}" 2>&1 >> "${LOG_SUSPECTED}" || :
        fi
    done
}

EXAMPLE_NUM=0

EXAMPLE_PATHS=$( find ${IDF_PATH}/examples/ -type f -name Makefile | grep -v "/components/" | grep -v "/common_components/" | grep -v "/main/" | grep -v "/build_system/cmake/" | grep -v "/mb_example_common/" | sort )
for FN in ${EXAMPLE_PATHS}
do
    if [[ $EXAMPLE_NUM -lt $START_NUM || $EXAMPLE_NUM -ge $END_NUM ]]
    then
        EXAMPLE_NUM=$(( $EXAMPLE_NUM + 1 ))
        continue
    fi
    echo ">>> example [ ${EXAMPLE_NUM} ] - $FN"

    build_example "${EXAMPLE_NUM}" "${FN}"

    EXAMPLE_NUM=$(( $EXAMPLE_NUM + 1 ))
done

# show warnings
echo -e "\nFound issues:"

#       Ignore the next messages:
# "error.o" or "-Werror" in compiler's command line
# "reassigning to symbol" or "changes choice state" in sdkconfig
# 'Compiler and toochain versions is not supported' from make/project.mk
IGNORE_WARNS="\
library/error\.o\
\|\ -Werror\
\|error\.d\
\|reassigning to symbol\
\|changes choice state\
\|Compiler version is not supported\
\|Toolchain version is not supported\
"

sort -u "${LOG_SUSPECTED}" | grep -v "${IGNORE_WARNS}" \
    && RESULT=$RESULT_ISSUES \
    || echo -e "\tNone"

[ -z ${FAILED_EXAMPLES} ] || echo -e "\nThere are errors in the next examples: $FAILED_EXAMPLES"
[ $RESULT -eq 0 ] || echo -e "\nFix all warnings and errors above to pass the test!"

echo -e "\nReturn code = $RESULT"

exit $RESULT
