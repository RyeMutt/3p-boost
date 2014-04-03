#!/bin/bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
set -x
# make errors fatal
set -e

BOOST_SOURCE_DIR="boost"

if [ -z "$AUTOBUILD" ] ; then 
    fail
fi


BOOST_BJAM_OPTIONS="address-model=32 architecture=x86 --layout=tagged \
                            --with-context --with-date_time --with-filesystem \
                            --with-iostreams --with-program_options \
                            --with-regex --with-signals --with-system \
                            --with-thread --with-coroutine -sNO_BZIP2=1"

# regex tests disabled due to failure in 1.55.0 (re-enable later) - Bug 9555
BOOST_TEST_LIBS_COMMON="context program_options signals system thread coroutine"
BOOST_TEST_LIBS_LINUX="${BOOST_TEST_LIBS_COMMON} date_time iostreams"
BOOST_TEST_LIBS_WINDOWS="${BOOST_TEST_LIBS_COMMON} filesystem"
# No filesystem test for darwin due to Bug 9560 - may have production implications, too
BOOST_TEST_LIBS_DARWIN="${BOOST_TEST_LIBS_COMMON} date_time iostreams"
BOOST_BUILD_SPAM="-d2 -d+4"             # -d0 is quiet, "-d2 -d+4" allows compilation to be examined

top="$(pwd)"
cd "$BOOST_SOURCE_DIR"
bjam="$(pwd)/bjam"
stage="$(pwd)/stage"
[ -f "$stage"/packages/include/zlib/zlib.h ] || fail "You haven't installed packages yet."
                                                     
if [ "$OSTYPE" = "cygwin" ] ; then
    export AUTOBUILD="$(cygpath -u $AUTOBUILD)"
    # Bjam doesn't know about cygwin paths, so convert them!
fi

# load autobuild provided shell functions and variables
set +x
eval "$("$AUTOBUILD" source_environment)"
set -x

stage_lib="${stage}"/lib
stage_release="${stage_lib}"/release
stage_debug="${stage_lib}"/debug
mkdir -p "${stage_release}"
mkdir -p "${stage_debug}"

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/debug/libz.so*.disable "${stage}"/packages/lib/release/libz.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}

# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/{debug,release}/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

# bjam doesn't support a -sICU_LIBPATH to point to the location
# of the icu libraries like it does for zlib. Instead, it expects
# the library files to be immediately in the ./lib directory
# and the headers to be in the ./include directory and doesn't
# provide a way to work around this. Because of this, we break
# the standard packaging layout, with the debug library files
# in ./lib/debug and the release in ./lib/release and instead
# only package the release build of icu4c in the ./lib directory.
# If a way to work around this is found, uncomment the
# corresponding blocks in the icu4c build and fix it here.

case "$AUTOBUILD_PLATFORM" in

    "windows")
        INCLUDE_PATH=$(cygpath -m "${stage}"/packages/include)
        ZLIB_RELEASE_PATH=$(cygpath -m "${stage}"/packages/lib/release)
        ZLIB_DEBUG_PATH=$(cygpath -m "${stage}"/packages/lib/debug)
        ICU_PATH=$(cygpath -m "${stage}"/packages)

        # Odd things go wrong with the .bat files:  branch targets
        # not recognized, file tests incorrect.  Inexplicable but
        # dropping 'echo on' into the .bat files seems to help.
        cmd.exe /C bootstrap.bat vc10

        # Windows build of viewer expects /Zc:wchar_t-, have to match that
        WINDOWS_BJAM_OPTIONS="--toolset=msvc-10.0 -j2 \
            include=$INCLUDE_PATH -sICU_PATH=$ICU_PATH \
            -sZLIB_INCLUDE=$INCLUDE_PATH/zlib \
            cxxflags=-Zc:wchar_t- \
            $BOOST_BJAM_OPTIONS"

        DEBUG_BJAM_OPTIONS="$WINDOWS_BJAM_OPTIONS -sZLIB_LIBPATH=$ZLIB_DEBUG_PATH -sZLIB_LIBRARY_PATH=$ZLIB_DEBUG_PATH -sZLIB_NAME=zlibd"
        "${bjam}" link=static variant=debug \
            --prefix="${stage}" --libdir="${stage_debug}" $DEBUG_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # Windows unit tests seem confused more than usual.  So they're
        # disabled for now but should be tried with every update.

        # conditionally run unit tests
        # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
        #     for blib in $BOOST_TEST_LIBS_WINDOWS; do
        #         cd libs/"$blib"/test
        #             "${bjam}" link=static variant=debug \
        #                 --prefix="${stage}" --libdir="${stage_debug}" \
        #                 $DEBUG_BJAM_OPTIONS $BOOST_BUILD_SPAM -a -q
        #         cd ../../..
        #     done
        # fi

        RELEASE_BJAM_OPTIONS="$WINDOWS_BJAM_OPTIONS -sZLIB_LIBPATH=$ZLIB_RELEASE_PATH -sZLIB_LIBRARY_PATH=$ZLIB_RELEASE_PATH -sZLIB_NAME=zlib"
        "${bjam}" link=static variant=release \
            --prefix="${stage}" --libdir="${stage_release}" $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        # if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
        #     for blib in $BOOST_TEST_LIBS_WINDOWS; do
        #         cd libs/"$blib"/test
        #             "${bjam}" link=static variant=release \
        #                 --prefix="${stage}" --libdir="${stage_debug}" \
        #                 $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM -a -q
        #         cd ../../..
        #     done
        # fi

        # Move the debug libs first, then the leftover release libs
        mv "${stage_lib}"/*-gd.lib "${stage_debug}"
        mv "${stage_lib}"/*.lib "${stage_release}"
        ;;

    "darwin")
        # boost::future appears broken on 32-bit Mac (see boost bug 9558).
        # Disable the class in the unit test runs and *don't use it* in 
        # production until it's known to be good.
        BOOST_CXXFLAGS="-gdwarf-2 -DBOOST_THREAD_DONT_PROVIDE_FUTURE_CONTINUATION -DBOOST_THREAD_DONT_PROVIDE_FUTURE_CTOR_ALLOCATORS -DBOOST_THREAD_DONT_PROVIDE_FUTURE_CONTINUATION -DBOOST_THREAD_DONT_PROVIDE_FUTURE_UNWRAP -DBOOST_THREAD_DONT_PROVIDE_FUTURE_INVALID_AFTER_GET"

        # Force zlib static linkage by moving .dylibs out of the way
        trap restore_dylibs EXIT
        for dylib in "${stage}"/packages/lib/{debug,release}/*.dylib; do
            if [ -f "$dylib" ]; then
                mv "$dylib" "$dylib".disable
            fi
        done
            
        stage_lib="${stage}"/lib
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages

        DEBUG_BJAM_OPTIONS="include=\"${stage}\"/packages/include include=\"${stage}\"/packages/include/zlib/ \
            -sZLIB_LIBPATH=\"${stage}\"/packages/lib/debug \
            -sZLIB_INCLUDE=\"${stage}\"/packages/include/zlib/ \
            ${BOOST_BJAM_OPTIONS}"

        "${bjam}" toolset=darwin variant=debug $DEBUG_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in $BOOST_TEST_LIBS_DARWIN; do
                cd libs/"${blib}"/test
                    "${bjam}" toolset=darwin variant=debug -a -q \
                        $DEBUG_BJAM_OPTIONS $BOOST_BUILD_SPAM cxxflags="$BOOST_CXXFLAGS"
                cd ../../..
            done
        fi

        mv "${stage_lib}"/*.a "${stage_debug}"

        RELEASE_BJAM_OPTIONS="include=\"${stage}\"/packages/include include=\"${stage}\"/packages/include/zlib/ \
            -sZLIB_LIBPATH=\"${stage}\"/packages/lib/release \
            -sZLIB_INCLUDE=\"${stage}\"/packages/include/zlib/ \
            ${BOOST_BJAM_OPTIONS}"

        "${bjam}" toolset=darwin variant=release $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM stage
        
        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in $BOOST_TEST_LIBS_DARWIN; do
                cd libs/"${blib}"/test
                    "${bjam}" toolset=darwin variant=release -a -q \
                        $RELEASE_BJAM_OPTIONS $BOOST_BUILD_SPAM cxxflags="$BOOST_CXXFLAGS"
                cd ../../..
            done
        fi

        mv "${stage_lib}"/*.a "${stage_release}"
        ;;

    "linux")
        # Force static linkage to libz by moving .sos out of the way
        trap restore_sos EXIT
        for solib in "${stage}"/packages/lib/debug/libz.so* "${stage}"/packages/lib/release/libz.so*; do
            if [ -f "$solib" ]; then
                mv -f "$solib" "$solib".disable
            fi
        done
            
        ./bootstrap.sh --prefix=$(pwd) --with-icu="${stage}"/packages/

        DEBUG_BOOST_BJAM_OPTIONS="toolset=gcc-4.6 include=$stage/packages/include/zlib/ \
            -sZLIB_LIBPATH=$stage/packages/lib/debug \
            -sZLIB_INCLUDE=\"${stage}\"/packages/include/zlib/ \
            $BOOST_BJAM_OPTIONS"
        "${bjam}" variant=debug --reconfigure \
            --prefix="${stage}" --libdir="${stage}"/lib/debug \
            $DEBUG_BOOST_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in $BOOST_TEST_LIBS_LINUX; do
                cd libs/"${blib}"/test
                    "${bjam}" variant=debug -a -q \
                        --prefix="${stage}" --libdir="${stage}"/lib/debug \
                        $DEBUG_BOOST_BJAM_OPTIONS $BOOST_BUILD_SPAM
                cd ../../..
            done
        fi

        mv "${stage_lib}"/libboost* "${stage_debug}"

        "${bjam}" --clean

        RELEASE_BOOST_BJAM_OPTIONS="toolset=gcc-4.6 include=$stage/packages/include/zlib/ \
            -sZLIB_LIBPATH=$stage/packages/lib/release \
            -sZLIB_INCLUDE=\"${stage}\"/packages/include/zlib/ \
            $BOOST_BJAM_OPTIONS"
        "${bjam}" variant=release --reconfigure \
            --prefix="${stage}" --libdir="${stage}"/lib/release \
            $RELEASE_BOOST_BJAM_OPTIONS $BOOST_BUILD_SPAM stage

        # conditionally run unit tests
        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
            for blib in $BOOST_TEST_LIBS_LINUX; do
                cd libs/"${blib}"/test
                    "${bjam}" variant=release -a -q \
                        --prefix="${stage}" --libdir="${stage}"/lib/release \
                        $RELEASE_BOOST_BJAM_OPTIONS $BOOST_BUILD_SPAM
                cd ../../..
            done
        fi

        mv "${stage_lib}"/libboost* "${stage_release}"

        "${bjam}" --clean
        ;;
esac
    
mkdir -p "${stage}"/include
cp -a boost "${stage}"/include/
mkdir -p "${stage}"/LICENSES
cp -a LICENSE_1_0.txt "${stage}"/LICENSES/boost.txt

cd "$top"

pass

