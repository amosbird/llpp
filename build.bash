#!/bin/bash
set -eu

now() { date +%s; }
S=$(now)
vecho() { ${vecho-:} "$*"; }
digest() { cat $* | cksum; } 2>/dev/null
die() { echo "$*" >&2; exit 111; }
partmsg() { echo "$(test $? -eq 0 || echo "fail ")$(($(now) - $S)) sec"; }

trap 'partmsg' EXIT

darwin=false
wsid="wsi/x11"
case "$(uname)" in
    Darwin)
        darwin=true
        wsid="wsi/cocoa"
        mjobs=$(getconf _NPROCESSORS_ONLN || echo 1);;
    Linux) mjobs=$(getconf _NPROCESSORS_ONLN || echo 1);;
    OpenBSD) mjobs=$(getconf NPROCESSORS_ONLN || echo 1);;
    *) die $(uname) is not supported;;
esac

test -n "${1-}" || die "usage: $0 build-directory"

outd="$1"
srcd="$(dirname $0)"
mudir=$outd/mupdf
muinc="-I $mudir/include -I $mudir/thirdparty/freetype/include"

test -d "$mudir" || die muPDF not found, consult $(dirname $0)/BUILDING

mkdir -p $outd/{$wsid,lablGL}
:>$outd/ordered

isfresh() { test -r "$1.past" && . "$1.past" && test "$k" = "$2"; }

mbt=native
mulibs="$mudir/build/$mbt/libmupdf.a $mudir/build/$mbt/libmupdf-third.a"
make -s -C "$mudir" build=$mbt -j $mjobs libs

oincs() {
    local i=
    local incs1=
    local incs=
    case "${1#$outd/}" in
        lablGL/*) incs1="$incs1 lablGL";;
        main.cmo) incs1="$incs1 $wsid lablGL";;
        glutils.cmo|listview.cmo) incs1="$incs1 lablGL";;
        *) ;;
    esac
    for i in $incs1; do
        incs="$incs -I $srcd/$i -I $outd/$i"
    done
    echo "-I $srcd -I $outd $incs"
}

oflags() {
    case "${1#$outd/}" in
        lablGL/*) f="-g";;
        *) f="-g -strict-sequence -strict-formats -w @A";;
    esac
    echo "$(oincs $1) $f"
}

cflags() {
    case "${1#$outd/}" in
        version.o) f=-DLLPP_VERSION=$ver;;
        link.o)
            f="-g -std=c99 -O2 $muinc -Wall -Werror -Wextra -pedantic"
            f="$f -DKeySym=uint32_t"
            $darwin && f="$f -DCIDER -D_GNU_SOURCE" \
                    || f="$f -D_POSIX_C_SOURCE";;
        */keysym2ucs.o) f="-O2 -include inttypes.h -DKeySym=uint32_t";;
        */ml_*.o) f="-g -Wno-pointer-sign -O2";;
        *) f="-g -O2";;
    esac
    ! $darwin || f="$f -DGL_SILENCE_DEPRECATION"
    echo $f
}

mflags() {
    echo "-I $(ocamlc -where) -g -Wall -Werror -O2 -DGL_SILENCE_DEPRECATION"
}

overs="$(ocamlc -vnum 2>/dev/null)" || overs=""
test "$overs" = "4.07.1" || {
    url=https://caml.inria.fr/pub/distrib/ocaml-4.07/ocaml-4.07.1.tar.xz
    txz=$outd/$(basename $url)
    isfresh $txz $url || {
        executable_p() { command -v "$1" >/dev/null 2>&1; }
        if executable_p wget; then dl() { wget -q "$1" -O "$2"; }
        elif executable_p curl; then dl() { curl -L "$1" -o "$2"; }
        else die "no program to fetch remote urls found"
        fi
        dl $url $txz
        echo "k=$url" >$txz.past
    } && vecho "fresh $txz"
    absprefix=$(cd $outd &>/dev/null; pwd -P)
    export PATH=$absprefix/bin:$PATH
    isfresh $absprefix/bin/ocamlc "$url" || (
        tar xf $txz -C $outd
        bn=$(basename $url)
        cd $outd/${bn%.tar.xz}
        ./configure -prefix $absprefix                                      \
                    -no-graph -no-debugger -no-ocamldoc -no-native-compiler
        make -j $mjobs world
        make install
        echo "k='$url'" >$absprefix/bin/ocamlc.past
    ) && vecho "fresh ocamlc"
    overs=$(ocamlc -vnum 2>/dev/null)
}

bocaml1() {
    grep -q "$3" $outd/ordered || {
        bocaml2 $*
        echo "$3" >>"$outd/ordered"
    }
}

bocaml2() {
    local n=$1
    local s="$2"
    local o="$3"
    local O=${4-}
    local dd

    local cmd="ocamlc -depend -bytecode -one-line $(oincs $o) $s"
    local keycmd="digest $o.depl $s"
    test -r $o.depl && isfresh "$o.depl" "$overs$cmd$(eval $keycmd)" || {
        eval "$cmd || die '$cmd' failed" | {
            read _ _ depl
            :>"$o.depl"
            for d in $depl; do
                local D=${d#$srcd/}
                test "$O" = "$D" || {
                    bocaml "$D" $((n+1))
                    case $d in
                        $outd/*) dd=$d;;
                        *) dd=$outd/${d#$srcd/};;
                    esac
                    printf "$dd " >>"$o.depl"
                }
            done
        } || die "$cmd failed"
        echo "k='$overs$cmd$(eval $keycmd)'" >"$o.depl.past"
    } && {
        vecho "fresh $o.depl"
        for d in $(< $o.depl); do
            bocaml ${d#$outd/} $((n+1))
        done
    }

    cmd="ocamlc $(oflags $o) -c -o $o $s"
    keycmd="digest $o $s $(< $o.depl)"
    isfresh "$o" "$overs$cmd$(eval $keycmd)" || {
        printf "%*.s%s -> %s\n" $n '' "${s#$srcd/}" "${o#$outd/}"
        eval "$cmd || die '$cmd failed'"
        echo "k='$overs$cmd$(eval $keycmd)'" >"$o.past"
    } && vecho "fresh '$o'"
}

cycle=
bocaml() (
    local o="$1"
    local n="$2"
    local wocmi="${o%.cmi}"
    local s
    local cycle1=$cycle
    case ${wocmi#$outd/} in
        confstruct.cmo)
            s=$outd/confstruct.ml
            o=$outd/confstruct.cmo;;
        *)
            test "$o" = "$wocmi" && s=$srcd/${o%.cmo}.ml || s=$srcd/$wocmi.mli
            o=$outd/$o;;
    esac
    expr >/dev/null "$cycle" : ".*$o" && die cycle $o || cycle="$cycle$o"
    bocaml1 $n "$s" "$o"
    case $wocmi in
        wsi) s="$srcd/$wsid/wsi.ml";;
        help) s="$srcd/help.ml";;
        */glMisc) s="$srcd/lablGL/glMisc.ml";;
        */glTex) s="$srcd/lablGL/glTex.ml";;
        *) false;;
    esac && {
        local s1=${s#$srcd/}
        bocaml1 $n "$s" "$outd/${s1%.ml}.cmo" "${o#$outd/}"
    } || true
    cycle=$cycle1
)

bocamlc() {
    local o=$outd/$1
    local s=$srcd/${1%.o}.c
    local cc=${LLPP_CC:+-cc \"$LLPP_CC\" }
    local cmd="ocamlc $cc-ccopt \"$(cflags $o) -MMD -MF $o.dep -MT_ -o $o\" $s"
    test -r $o.dep && read _ d <$o.dep || d=
    local keycmd='digest $o $d'
    isfresh "$o" "$overs$cmd$(eval $keycmd)" || {
        printf "%s -> %s\n" "${s#$srcd/}" "${o#$outd/}"
        eval "$cmd || die '$cmd failed'"
        read _ d <$o.dep
        echo "k='$overs$cmd$(eval $keycmd)'" >"$o.past"
    } && vecho "fresh $o"
}

bocamlobjc() {
    local o=$outd/$1
    local s=$srcd/${1%.o}.m
    local cmd="$mcomp $(mflags $o) -MD -MF $o.dep -MT_ -c -o $o $s"
    test -r $o.dep && read _ d <$o.dep || d=
    local keycmd='digest $o $d'
    isfresh "$o" "$overs$cmd$(eval $keycmd)" || {
        printf "%s -> %s\n" "${s#$srcd/}" "${o#$outd/}"
        eval "$cmd || die '$cmd failed'"
        read _ d <$o.dep
        echo "k='$overs$cmd$(eval $keycmd)'" >"$o.past"
    } && vecho "fresh $o"
}

ver=$(cd $srcd && git describe --tags --dirty) || ver=unknown

cmd="(. $srcd/genconfstr.sh >$outd/confstruct.ml)"
keycmd="digest $srcd/genconfstr.sh $outd/confstruct.ml"
isfresh "$outd/confstruct.ml" "$cmd$(eval $keycmd)" || {
    echo "generating $outd/confstruct.ml"
    eval "$cmd || die genconfstr.sh failed"
    echo "k='$cmd$(eval $keycmd)'" > "$outd/confstruct.ml.past"
} && vecho "fresh $outd/confstruct.ml"

shift 1
for target; do
    case "$target" in
        doc)
            doct=${doct-manpage}
            md=$outd/doc
            mkdir -p $md
            case $doct in
                epub) suf=.epub;;
                manpage) suf=.1;;
                *) die "unknown doc type";;
            esac
            for m in llpp llppac llpphtml; do
                src=$srcd/adoc/$m.adoc
                out=$md/$m$suf
                conf="$srcd/man/asciidoc.conf"
                keycmd="digest $out $src $conf"
                cmd="a2x -D $md -d manpage -f $doct $src"
                isfresh "$out" "$cmd$(eval $keycmd)" || {
                    echo "$src -> $out"
                    eval "$cmd || die '$cmd failed'"
                    echo "k='$cmd$(eval $keycmd)'" >"$out.past"
                } && vecho "fresh $out"
            done;;

        completions) die "not yet";;

        *) die "no clue - '$target'";;
    esac
done

bocaml main.cmo 0

cobjs=
for m in link cutils version; do
    bocamlc $m.o
    cobjs="$cobjs $outd/$m.o"
done
for m in ml_gl ml_glarray ml_raw; do
    bocamlc lablGL/$m.o
    cobjs="$cobjs $outd/lablGL/$m.o"
done

libs="str.cma unix.cma"
clibs="-L$mudir/build/$mbt -lmupdf -lmupdf-third -lpthread"
if $darwin; then
    mcomp=$(ocamlc -config | grep bytecomp_c_co | { read _ c; echo $c; })
    clibs="$clibs -framework Cocoa -framework OpenGL"
    cobjs="$cobjs $outd/wsi/cocoa/cocoa.o"
    bocamlobjc wsi/cocoa/cocoa.o
else
    clibs="$clibs -lGL -lX11"
    cobjs="$cobjs $outd/wsi/x11/keysym2ucs.o $outd/wsi/x11/xlib.o"
    bocamlc wsi/x11/keysym2ucs.o
    bocamlc wsi/x11/xlib.o
fi

ord=$(grep -v \.cmi $outd/ordered)
cmd="ocamlc -custom $libs -o $outd/llpp $cobjs $(echo $ord) -cclib \"$clibs\""
keycmd="digest $outd/llpp $cobjs $ord $mulibs"
isfresh "$outd/llpp" "$cmd$(eval $keycmd)" || {
    echo linking $outd/llpp
    eval "$cmd || die '$cmd failed'"
    echo "k='$cmd$(eval $keycmd)'" >"$outd/llpp.past"
} && vecho "fresh llpp"

if $darwin; then
    out="$outd/llpp.app/Contents/Info.plist"
    keycmd="digest $out $srcd/wsi/cocoa/genplist.sh; echo $ver"
    isfresh $out "$(eval $keycmd)" || {
        d=$(dirname $out)
        mkdir -p "$d"
        echo "generating $out"
        (. $srcd/wsi/cocoa/genplist.sh) >"$out"
        echo "k='$(eval $keycmd)'" >"$out.past"
    } && vecho "fresh plist"

    out=$outd/llpp.app/Contents/MacOS/llpp
    keycmd="digest $out $outd/llpp"
    isfresh $out "$(eval $keycmd)" || {
        echo "bundling $out"
        mkdir -p "$(dirname $out)"
        cp $outd/llpp $out
        echo "k='$(eval $keycmd)'" >"$out.past"
    } && vecho "fresh bundle"
fi
