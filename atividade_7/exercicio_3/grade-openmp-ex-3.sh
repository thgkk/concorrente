#!/bin/bash
# Usage: grade dir_or_archive [output]

# Ensure realpath 
realpath . &>/dev/null
HAD_REALPATH=$(test "$?" -eq 127 && echo no || echo yes)
if [ "$HAD_REALPATH" = "no" ]; then
  cat > /tmp/realpath-grade.c <<EOF
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char** argv) {
  char* path = argv[1];
  char result[8192];
  memset(result, 0, 8192);

  if (argc == 1) {
      printf("Usage: %s path\n", argv[0]);
      return 2;
  }
  
  if (realpath(path, result)) {
    printf("%s\n", result);
    return 0;
  } else {
    printf("%s\n", argv[1]);
    return 1;
  }
}
EOF
  cc -o /tmp/realpath-grade /tmp/realpath-grade.c
  function realpath () {
    /tmp/realpath-grade $@
  }
fi

INFILE=$1
if [ -z "$INFILE" ]; then
  CWD_KBS=$(du -d 0 . | cut -f 1)
  if [ -n "$CWD_KBS" -a "$CWD_KBS" -gt 20000 ]; then
    echo "Chamado sem argumentos."\
         "Supus que \".\" deve ser avaliado, mas esse diretório é muito grande!"\
         "Se realmente deseja avaliar \".\", execute $0 ."
    exit 1
  fi
fi
test -z "$INFILE" && INFILE="."
INFILE=$(realpath "$INFILE")
# grades.csv is optional
OUTPUT=""
test -z "$2" || OUTPUT=$(realpath "$2")
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
# Absolute path to this script
THEPACK="${DIR}/$(basename "${BASH_SOURCE[0]}")"
STARTDIR=$(pwd)

# Split basename and extension
BASE=$(basename "$INFILE")
EXT=""
if [ ! -d "$INFILE" ]; then
  BASE=$(echo $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\1/g')
  EXT=$(echo  $(basename "$INFILE") | sed -E 's/^(.*)(\.(c|zip|(tar\.)?(gz|bz2|xz)))$/\2/g')
fi

# Setup working dir
rm -fr "/tmp/$BASE-test" || true
mkdir "/tmp/$BASE-test" || ( echo "Could not mkdir /tmp/$BASE-test"; exit 1 )
UNPACK_ROOT="/tmp/$BASE-test"
cd "$UNPACK_ROOT"

function cleanup () {
  test -n "$1" && echo "$1"
  cd "$STARTDIR"
  rm -fr "/tmp/$BASE-test"
  test "$HAD_REALPATH" = "yes" || rm /tmp/realpath-grade* &>/dev/null
  return 1 # helps with precedence
}

# Avoid messing up with the running user's home directory
# Not entirely safe, running as another user is recommended
export HOME=.

# Check if file is a tar archive
ISTAR=no
if [ ! -d "$INFILE" ]; then
  ISTAR=$( (tar tf "$INFILE" &> /dev/null && echo yes) || echo no )
fi

# Unpack the submission (or copy the dir)
if [ -d "$INFILE" ]; then
  cp -r "$INFILE" . || cleanup || exit 1 
elif [ "$EXT" = ".c" ]; then
  echo "Corrigindo um único arquivo .c. O recomendado é corrigir uma pasta ou  arquivo .tar.{gz,bz2,xz}, zip, como enviado ao moodle"
  mkdir c-files || cleanup || exit 1
  cp "$INFILE" c-files/ ||  cleanup || exit 1
elif [ "$EXT" = ".zip" ]; then
  unzip "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.gz" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.bz2" ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".tar.xz" ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "yes" ]; then
  tar zxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".gz" -a "$ISTAR" = "no" ]; then
  gzip -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "yes"  ]; then
  tar jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".bz2" -a "$ISTAR" = "no" ]; then
  bzip2 -cdk "$INFILE" > "$BASE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "yes"  ]; then
  tar Jxf "$INFILE" || cleanup || exit 1
elif [ "$EXT" = ".xz" -a "$ISTAR" = "no" ]; then
  xz -cdk "$INFILE" > "$BASE" || cleanup || exit 1
else
  echo "Unknown extension $EXT"; cleanup; exit 1
fi

# There must be exactly one top-level dir inside the submission
# As a fallback, if there is no directory, will work directly on 
# tmp/$BASE-test, but in this case there must be files! 
function get-legit-dirs  {
  find . -mindepth 1 -maxdepth 1 -type d | grep -vE '^\./__MACOS' | grep -vE '^\./\.'
}
NDIRS=$(get-legit-dirs | wc -l)
test "$NDIRS" -lt 2 || \
  cleanup "Malformed archive! Expected exactly one directory, found $NDIRS" || exit 1
test  "$NDIRS" -eq  1 -o  "$(find . -mindepth 1 -maxdepth 1 -type f | wc -l)" -gt 0  || \
  cleanup "Empty archive!" || exit 1
if [ "$NDIRS" -eq 1 ]; then #only cd if there is a dir
  cd "$(get-legit-dirs)"
fi

# Unpack the testbench
tail -n +$(($(grep -ahn  '^__TESTBENCH_MARKER__' "$THEPACK" | cut -f1 -d:) +1)) "$THEPACK" | tar zx
cd testbench || cleanup || exit 1

# Deploy additional binaries so that validate.sh can use them
test "$HAD_REALPATH" = "yes" || cp /tmp/realpath-grade "tools/realpath"
export PATH="$PATH:$(realpath "tools")"

# Run validate
(./validate.sh 2>&1 | tee validate.log) || cleanup || exit 1

# Write output file
if [ -n "$OUTPUT" ]; then
  #write grade
  echo "@@@###grade:" > result
  cat grade >> result || cleanup || exit 1
  #write feedback, falling back to validate.log
  echo "@@@###feedback:" >> result
  (test -f feedback && cat feedback >> result) || \
    (test -f validate.log && cat validate.log >> result) || \
    cleanup "No feedback file!" || exit 1
  #Copy result to output
  test ! -d "$OUTPUT" || cleanup "$OUTPUT is a directory!" || exit 1
  rm -f "$OUTPUT"
  cp result "$OUTPUT"
fi

if ( ! grep -E -- '-[0-9]+' grade &> /dev/null ); then
   echo -e "Grade for $BASE$EXT: $(cat grade)"
fi

cleanup || true

exit 0

__TESTBENCH_MARKER__
�      �<mS�H��z�ᰲ���	���������k#K�$CB�su����>\=u��Ǯ{f$�dِ<l��6�Y3==�=�=�=�#F�5G�G�Մk���{k�Ӕ��������Zm�5WW5[���#���HJ�I!��~���pw��?��d�#�s�?D�|��;+����\���_N\3�=��ؽk�WZ˹�_]YY{D�3���/����۸0�Q�������@���,�J����������v(�]R~�A,�D�=$���@�Fߓ&9� ш��GZ�c>L5��(ey
�"P�E͑G���^���j��=c|aA`h����^�r���H�"g�V�S$(�s)|�NH�3g�	��v�u��K�\s�����������W[���[\���>����=n��ڥ�ZD��D	����UՄm!��`�O�f[�7�z^��J�S��������~:�V��>aC�qv�:;k�:���_� qg@'�	�
����L���刺
*�����8��lj��i�長�����vm����q������N���n�����pM�{0�F������e�A?���6�+�����흟6˝��\�i�V���;I@�j��aA��C�2�G �C�O�lfx�C��#�C���\�;�[C��� �$��*�0��_W�!�=��$��40\�#c��dL|obz�z��BZ�iȒ#�N���^�Ǥ8��A�$��h�,j�Ά��3�lq��"gh>�i�(ghRb����?L��ipI��б;쿽<e���+����\������w�z�d�" �e��]*��_�L�)��
��C֙�#��A� ��p��g�Rj]�y�$j4�>�OB㒮�r�S�{�XL�N�Hg9�x���├���� �h��܀�R��\�H��)�nD�
�`��{�=�`��^�E�������˅��rk]�h�&�I�h�:<��a��mU G�z6�yM�Y|��˦��A����ưK�J%�d���_�ϫ�w�W 	`3)��IcL�͆k1T�"�is�H�R�.�T
�HqNJo��T����$}��W�/�LB�pd��a�ی�T{jY&>����AR@vp#K YM��(e[��9�ܝXB��5�.LLFv�*�A<I���Q�R*9'+�N	Oq��}h�qӳ!���v�!9S����3�F�L�J�[�R~���L��/b�CDy���`�1g
����V��0����;@����!l�՛�F��B�2��/�'W��_�m�hI[}� s�&���2s�o�M��������\�е�������ۃ��>�^u{;?�?�zi�m0����5�	x��ad�e}��m��l���A��D���B�];�Eb���Jm�l��<�ʂ[�x����Of���Æ]8�9^��&��� +���_u<�Q؟qHͰ��u(>1#��@6bfG���_�9�Q?#�o����-E5s��9� �p
ɜ����F�>�W� <*d���/��ӹ����i,;V|�R��5�D����бMʞľVp\�m�E�?E4��v��z�b�F,v��V3�����1��b���dp�U�j��ȆG�s��`����v8�j�}��X����T�2�i�6�� ���E¦�Q0���J2i|�����̟��#f1����p�Y�/�Z84�3]N��}�k��o>����Vgmyuz�_����k�6m�`�Q~7�`z�w�l7���d�&���mc#�F~�d2�JaĪ`8�c��y��p{��s̼S6\���m"�L��<�m���w�a8���`O;�C�5 ����b��?��_��PuQ���D5Ҭ���Ǉ�=�m{�_g��z����G�3G/`�Hr��Q {,�"P���z4OYP��F���`�<�h~_3Œ�1q�aI���]�}�)��>��{,��>�7'']<Æ8���;�Ia�i�t��"63ϙn�F9�l@����FÀ�m�"���xA��'��4�QŸF�	�*d��� �ѳf�DZ|���?���F
�$PFġ��2ݘ`g=�� �M�$D���M��fck-ՃH$��gH��8T� /��@UN���i1����
	�4�����eVH�im�)OB,���H�Y��͊V�&iF*�[�3(EYf��H���2�P�/K�̋��y��i��� l��+1�C1�%�:'�&X�3��$�����Iv*xJ�bh:^H��ST��$�Ǆ�ة͠g~B�^w`S&�ȇ��"ŦHKA�I��m�����l�՘I��v�bב̂�O�Dk��Ǜ�3��>c�*��2�JYj-�Rk��������rN�<��K-������(��P���ќU���Cr�Dr,�J �E���h:�p�N25yL�f�P#	¶y�
ʲ��ة�S���i`���	����S&��d@V�v%ŀދ5%�
[�*DWh5E!!��&S�m4��kEV��"ǒ��*�%�]K
P	��g�-�xFyJL�/<E!P���4Z���6�S�����c����Ǳ/F��f�mF�k.nB�j|Г��.:���6��x.\3�3��F����M���{�;5DTR%�����*��c�u%��D!c��}3�s�k��`
 i<T��]�$d��P��O�����C�M����L`�� ��T�ٴ��X��#dS���f	u��x�ٖ6��ɰ3_Ѹ%�r���n�������XAQA��W �M�8����3�3��{ӂj8[�H��h���E��cL-"Mo{��{{Yib����l��yO�@��
��O@�[v<���Ѝ�+�x��.����Mym;#�<	�\mכ�)�mD��<������M�;�"�N*�gG	�RŲ���|��z��?�dݣ70|�X�V�c/�<�{D���|��$�Bx(���Jӟ����"�@�z���z�3Y�+�dߒC�Ks���Ҥ����%.W����F�;�(�5x�w۸킐~�g[|�'x�X8FX=�j�^鼊���=:=g�� |����\#�v}y#�z�U#k��<u�O��[���FV�kO;x�4[xk?[�[keE�Z�7� �\�����NokO���/�W����
��dg��uڷ�GH��`�ɔ��Yo�!z8�ʹ��*�C���N@��BQ��y!��^��1�.��'��l��猁��� ,l�)%����z\��uo� 
�}�Z��� ��:	���=�h5�Z+v"��P�7E��8�
c9x���-�Sv��0��R �0Uv� K	��h+��C����.�����^
ga��>O%��>U}�r�څ܁1��
n�$�V������_��}^Q�_�=���I�wr�Zejy�	l�Υ��=�Q�bn��U��#��:dy�K$�X�Z,����8r� �V�WH���I��J$�,1&4�t��� �`��`
�l�˥��J���̔��T�
r_j� T��E����>�+:�eo�� |��߻��k�v��wy������*<�{{�c��^�Oz��{lGᝇ��ؿ�z�	q6�6ǜ8F �'����Tõ���-ze�en5i ��FD�;=�յ�a�lO4�K�Ʒ�*>\e�.=�f��(�Y��rl �3�q�Â��Z��suiFT���u!�4x�3+��	��e�� "�H�ġ�t��z��-���2��l���չ҇�^�zⰕ����a<m�# ����� %�]�cy/N�;*�	u�E�J(����F�;�=�҂q��9�Io��D �X���A�EYu�� ����2"�)p�����Ǵ��و +HDu��}	|�3z`_�6�XS��bU�dT Ņ�'��h������%�M�.�ޯ���y��5���lH���MAQ�t<�Z��G�^�"�kS��J��K��<m�a-�����l|�;�H��6�JL��%#��hy`-��Q���1
~_��E�8v���k$),��l?�괤P������p�Ib?��M�[���
|E�	�3�"��9o�Roz�?���U?�Ha1�e�`����~�ݖ�>��Ԣ�0S�Z֛���&�R�r0�`��0�sƎ�"��Yo7f�
�G�32�xl-�` 8����~U�d6���|1��j���*�bk~w� �̞�kfn�J�w��Dߞ�_�P�H�=+�6�Ӂ����%�B�=T���wx�������~�W��)���ϤahX^�ţ����MB�~���i렛XruAS�G�tŇރ��.�.���o��i���/�axa��5Z��pR}Am��pW�����뇋Z ����o&���&5�V�|v��ՙ�����I蛚Ö3�;	����7�x52��j�Ra� ����ő-�:���w�ᑍ~��:?C���?<�dġWބ<�/�"�a��y�zs�����r~q�c`'_u�K`Bo�#[s�J����R�-ɑg1����p�:;j�n�<���u�ϸ��^�.=+C��_L|6M�����0�x���e��D�L�kQl�
�(�ເ��V�{:��W�	�9��[8
����<��������ƅ�\@K�F�����)�I
��2Dz�H��.X��8�ǟ�p�^$��$v���3v�Z�`#ik�i��>�Ԇ�}��?�'��hB̢��a'Y��/�n��T����-˪����Y
.<j��Ք�T��q�&��!x}\�:yc�ħ�]���B��2C/�
�cz?��0�>^�
�L�d|茁{�7�ii�B���S�qr�4LN�2�������>�[��u��L����������!��|�ZK^2�/I���_�?C�*N�F���<ml��|0��?�6�ۃ����[%8��@v�1��7�������x7���\x�'e�|��!����Q2}p�(�n^�^%�:��l�<��1ė�Òia�۷��������P�%1C�ߖI��r��L�̛���*D��J��z�H����B2I��/J�F,6l�y����������	@��EF�]w�J@,��ױ;���,w����f�������y}��w����?�vu�丫��?���?=ņ����/��~�?9��nB����� z
ށ!����'�%��M�&��'jY�Wjom��C�7����O�
�Q��iX䋡�4q�[;V��|S:��\�z����+�t�Vv���{��M4�n������* (��c�1ƆO�Ǡ���ľQ7�E���6I`T't|P�	9��A3O,r^�M��=�L�F$��v5��AX<�`�WƘ�7@.e~�9�	���=����0�7���@���'�yÜ����C���~�D��/�ϔ�%������P�x�
����_o4���ذ��C���Ҩ�xZ�0�+�5����ӄ�\�vI]�q[h����{3�=@{�f�����bb;V�\�,�d��R���ϖ��5�7(X��h䕸�o��k@d�����(���UYI���Pd~n�	%�jC��ɸ�r��`
����&7lw���VݲjG��f���s{��]Cg�k�~�V�����k�jZㆁ�y�+D��ֆ@OnZ��n	I�Є^Z[�8��Ų���c
=�֫�Xߌ��rk/�K���ћ�f��OW&������Bi/m/��o犡�O��(�ꭦ��H�[=3�J%J������Y��H�|�d�A&8���qA�a�^x����kD݌{�>XS	q{	�*DU� ��M�<\��e�o�Ho�0w
O����#mȼ�\�֑����6��h�8��}:�
�6~���?��je��hiJ�Qw����څ�N����L���R�䒼E�Pe��G�
��
�5+_�]��5/7ӄ%n���F���$B��︣m�����.�Bwc�o�����Q)�f5i�Y� <���vtL[7!X��AN-�I�m�4u�^fxz=H;Jtǉ7�/�k_7���"S%����J�[,��NG��f�@{>��c���'�UQ�w��h/��v�k(#<��>��<��;����&����8~~��M��jV��WN'S���)h��u�u�"ǘ�('�!!L���c%ԃ�uQ$9��YQYa���
7.�3�|I�cHm�3��7{kwXZ�\c���f(��2���~��������z&���������(���$���
_��\SN�X	ł3sPN�4��h�L�<R���}�0��L�@5�Ԃ̞�y3��l�c�ȫ�9t�i�`����u�����n�,fz���;�㈁w�؀��TU��:d�B-XO^<J���$�i�U���
�*K�(]�L�Z%{ �|�a�9�r����ƌ��k�D�66�'*3�iA���ʚ�ȑ��|;|ùծ0�C '��S����>���X{�K�(e��V�H
I�w��̙3gΜ9s�̙3gΜ9s�̙3g��� r@n x  