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
�      �<mSG��z�cY���;l��1�,q ǹ�5�Fh�}�@l���O=O�}�z����Ǯ{fvwVZ	����ī����������%dAx�c�x��]M�6:��6:M�_Z�k���Fs}�A��^k�= �?��􊂐��<����������
��]�
�-���_��}]�/rM���O��8r��t�{b���_k�N������Ҽ��_����qn:�sL
o�v������^��*��?:v[��등i1b:��l���!昜�!5��4��	'́>B��"��b�fАK�ŲD�3&.)���{��V󌼤��I}��P#=ӹ ������QZ��@�\��f�?��{lx矽ʵ���i�[��ٚ���z���K�������A_�>��v!`#R뙤4~:=*��BX~���ڇ��蕳
>�Kc׼��T;���Y�|z�J�����i[�Q�����;}F��N@и(��9�4i?�z��lz~�'��MKq�5�>����§#V��fxs�f���_��n��/q��������;���^���Ҫ���/���^o������R���Cj�qk���+I@#v�p"��A�)B� �G �ŘGJ|fx�R�G��l'�9���b���C�XNU�Ap�_��"�i37
���3r�M̀D6���p��:F��r�Ӑe��[�N"�;�>?���1R���9�[F֞d��$9G����r�&!��L�^��Ô5��̿���۫3��������ȥ�����^O��@j�xn
<�} L��J�/���s="�G^�䡸���P��G3fltN���0)��ܻ ��IJMA��"b9�YY��s�w=���	9��9�A����}�$�`a���9!���#�=����ݒv���&�l�Ϟ={��Q��Y�h�S���6�q���m�8R�+�q��0�n���"����+%M�aWZ�r<�,	'?m�U6o#@� �g*f��&�1a7^���e5M[�Gq�E���F��t���Le{?Aҗ8�b�Y1��"��*3|p����j�B���g�W3��<H
�nd䠪���b�,��W�N�!�ޞa�&&#;W�� ���BĨH)��˂�5T���8I>��^��|A�G�7�pLN�K����X%|��bYXi��L�a��X6�2�%��>t���`�q�E0u	)�<caCI�w��%��M�8�7����7�"��8��|؟\��I-sDCׯ%m�ɽ́���������1��w�_��/r=2�Έ�����s���3�����y�������A�	�;���t+��m��Q�lg�L7ۄq8�@P�,�<=<�M�E���WH���¥k���#����Zng�'3��6���a���W��9l���r�l�k�1
����t�A	
�GF�s�F�� t�+�3D�"'0/pn)��C\O�B�f�,,�A�h�>|���BF1���q~z��x�e��s�+�9Ұ�U�?d�����2Ɵ侖s\�o�EU<�̷u`�JT=�
1r#;C�ajAU`}��ڞ�bR�l>g��j�81���ޏݘ���_���e+T�*A���1�نq���@U$|ZS�m�$��\<�/��8=r#�%�A6o��Ŝ��\�Si|����Z���2������X]���׿��_�Z�M� �2���!؟��-�<��|ߙB��Zٶ�1at�ͦ�dj����N&�Z̍X����&u��^��s�WB�6D��R���X��q#� ���iȺ�D ���B������K0�b}�-��@=��J��<0��p�ϱ���ۜ�3C_���t�����я0o$S��{,�9"�P�I�/z�HYP��F����<yd� �<���%�#raI���]�����>��X��=�oAN*�x�-y8�wZ��r�V�:3�lf�3ݰ�
$ـ������5��3D�.��xI��.1�4j�(-#"�W����/Ab��"��X�5��`��\,	T�Q�mL���q��&�"�B]�����@Ku!�����!�2�˃n�׊'���欘�$�x�E�74��ݱl�⼐�(��=-.Xv��4 ��8?4�[����Ȯ���2+�D��U�!��~Z�'e�G̓�m�Be`st�À<�4^��sm��<%M���u^��d����q�)Ɔ�L�?E�L�{L����z'ĉ�u6e�|�/�Pl� ���4.�6o��	����P��8/h�A�+v�,h��t"Aj�3�K�9u�Q�3F��iʶpUr�Jk��Zc�~p��M�%���3"���_i��f��@�6X���G���t��8#�c!��/�"lN�؊�	:���1�;�OB�$�r�5/(��d�Oq6ߧ�QZ��'�6FO�b.K0eB�I� T�i�S�xS����kRt�V�S�b�l2yކC���*��<�ȱ$�䱊~lW�T'�����)�S��SN�� ���A-��`��YE�K�X�3:�q��0����ͩ|-��I�WUZJ[n����j����530:�/X�0�.�.^��ᠿ�[%@D9U�8XX8��O>"�m�[NpF��7�;ǽ�.�� P�&RA��KB�a/j��IB�|nZx�%�
���z�bLE��6;��p�jJY:�,�N:/>�J���5v����B4Aumv�kuqqp��~F%VR��L� �&���I��9�\M{Ӝj8_�(��i��E���L-#Mo���v�/˪���o�_`ٺ����$weR����78�x�3|}�C�r�W��t5�7^��[�iM\�p����)�M�( K�a~�%��i�fɿ�i�Z������H�b��`�\c=��?Q����+�X��+C��C�x�Q�C�ϕ�B�g�3%��쯼�=��$��`(���L���2�V�ošNKs��{i�{t��H@ȕz7�Dm���v�
!�P���&l���>���>�k��1
���v3��*�U��������%᫭���*i�뫫�ۭ*٨�6�S������U�V�x��[���[���Zkk�Z�������&�w�x�x��o����x���ĭ�!;O��Ӿ�9>B����N�L�������G����{I��;t�8a�d;.eZ���:�8;��")��8��f�6�}��"++@��6�Rrb��Y��!�����@��^i�` rP'I6��CG�f�;uf(�7E��8�cxR��/�S~��0s� ra*�. V i5Ж4��C��ql�Y�����n��R�y坴�RI{��4�+���� w �%�oR��@p��F!Li�8�;M�ҟ������Y�|�H�UЪR+rO`�u�L=]��3�8�*�&�/]�2Vs�@��Y�,oxɤ��O����$ξZ*@ƄՈ��^u�Ye%O�� �L��yu�D0MU0�T���R@L%̊�unJHd�c9����a ���͎G�������/�����m�ml�;3������E��#��G�9g�w<:���Z|��w�l���0��w��l�mPˈ,�C�)�w����lj:|����QN.�W�B`�ä�rt!�$S�[y��2u�P&�TM�l�F*D��y>��)ч�f�ĉ�x-�0P��Jn�b��d|<F(21���6�%��ux��3�k���w�=ql�:�'�h�P?��U1i�Ђ���8>^�5�" M�ȘE�n_�E.�=/޾#S�x�ƒ�lI�h�7rxu?0�3�GqɊ`k����E&�����rqn����UL�=YݴIħ�$��t,c�ɰ* ��J<�:N�HS8D7j�LO���C��4=8iw�a��:�!��4Em;my:Ӳ�ʎ�Iu��]#�����seb�;� �§�05@Е��*��J_$���F�df�d�8��|�*V�g���ے~E�nK� ��@�M�.m�����U�\��+=�!�!�Lqӣ���b���liR��������+^���Z,t�:�Ɯ$��[�r� ��U�T�:@��8J�塛�o�w��ۜ7ċ�d{/&'(%,��6��w"Kʃ�d�cM?����G�������X��9��J~�4�O�t��X	�M��KF��]t��0�&Y��/��U
�3>���tD��s�|߼0}�o����-<��M���Y&����)v-�Ϗ��C��Ώ�q"EX�C%֘��ݦ��!PKj���u��,�dr߻P*���a�3�j�u+3���Cf�Yn�L̜��t�l��n,_����b��0&&F5�s��� ����ri��.݈,�Wq���N^�������^�Xl~?�����W��5�-7�x����b��#����t2������_w ���:?�v�9�B4�<K�eq9mVm�:��q�,F$���D�*!�!�X���M���M��}���̖.�r~��k�y�<n��
.J���Z�`+iktɚt7�����\b���6T$�W|a�Ԗ�/�d]��T߂F�ҋ�Z�L�$�.'g�Ɩ��>��g��1�H��v@yL�!��g�ھ��`������j8sf|����`���%���G�Rd�$��s�ʭxv���9*�v��L�\&���������|��^��������:_���2�����:~Q[K>2Ɨd�G���?C�*N�����5��eb0�5x=<|=�B��m#.�oU���#�����ob���|W|��Hn���s<)�8��xL�6-y��w�*�
���j�x�E���v��=ӢO��X��ي��m�TH�C�%z�#s�*g#"�Zq��?���6R)
7�(�$�S֧�z#6��,���7��g�,J�	g�qCZ����K��u��og�Ӟ��f�k���\�/v^wk��Kj{������88����?Ɔ�������~<x}���B����� zr�� 5������`M{G��68.WߘS^zX.����P�� ���r�@m���ƨ�?�(di.d=K�`�9tZ`+{����q���{E��t\2�{�z��]�1��E�%x��AF��& ������}V�hc���L�hD!bp!,��k�&"a�o�0�@��C.	�{Im�2�H.�~�;�@ǌ��D�/ww9��s�������?f�0'6���$�GA�OCH8��m��q����� z
�%��,�$��F��tTx���Ӣ]R�`��B�&%��k�;��B��P�ޫ!��W����C��9�Lk�(U�ÑX2�:hF9�եq(����V�g����ݒv�����@����?pD���SC���O��BJ.5Ԇ)���������.�|w��W}d��̀�La��x޵�rp�SEg�k�c[X-����x�hD�Ay�Qs,�]�_�
�ÜԲ ͉�m�{:����,��gć,�FͰA/p�
��$�gR�q�M�H:��aCC�ʅ��w���o�4�,|����y`����}�n~Cu1���(%-�0�f��𿑥������ �?�U�f���߹	�ni�ѹu�
��:!F�"�v����v�e5n����ec����R�.����.�X�Ŏ����d�BW�u��9W�C!�v��?dIW�#yf�.�G�����ǁ��P��c�'&��'�����]��~̱ a��#H���+#_/C����Ȅ)b�O�D�ȊDĬ1,��.+�؆�m^��"썩�nBpj6�˄��U��L3�A>����Z<��=H�{�ӨuIu?|�X����n�7�?�TI��=־���v�
��p/�rPa����0N.��C���):�{Ց{�,�c����ˮ��/��h.�����(��h&��㢺9��;����W���xy�>��p_��"5|/�+׫�l�x
ޅb򺪋U��	�?4�Lb#(B��J�C����%��]�cJ8�UB)܀g���� 
��ԝ{+߻4;�쒲�@�ᚑ��S،���
������R�L�����Y?�n���p��,z1Ur�9-r%R[����.��u�2���r������E��(�fDZ0�gWbߓ��Q>V��~A�KP*��-�+�.��X�W����HEm��	�1����1ϳ�ˎ�l�M�%��\ѱz���4���upԤ1�b���2]H�Ο������\���&���kz�iWfVM���M[���U?��@αL�[�[�>rv��r���/��t���4�KY�ߢZX!��ϴ�� <��� x  