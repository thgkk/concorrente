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
�      �<�r�F�~5��M�H�I�l�t,K���Li$:ή$�Z@����q�b;���>LM��ij_�U?��t7n$Hډ��V�J�q���ܺ��)s��Ɲ?�jµ��ཱུ�if��u�����Zm�5WW�4[������XJ�(�O�j���`6ܢ��O�0��u������������"���_���F�����ܒ�����<1��++kwH�v�Ͽ����^��t�48S�l���/vv{�rKy�sp8趔�듑i1b:��l��B�9"G��A��ޑ&9� �s�!�X�Cm�M�iHJ�,�RE��g.)��{��V󄼤��I}�jh���I9A�Bd�$;�6W�@����Ɵ�pM�=2����?����Dc��7[���^m}��/qe������`g�/|c@[	�A��IJA���qPUuHa�[���j6��VO��\)�Q\������ۏ'����Gl(7��[�����l�_� �K�Qk�% h�Kov{Y�Է?��\�L��Hp�����kz}zM��اӮ���E���6Y�u:��W��W���w����{��M������A��,~w��/���E���|s��n����́L����?��a�ˆY/"LQ
P.�9θ,�<R������y�`@��.D���C�XI
QU�Ap��Kf�д��5����1\bS3 �M<7��z���B!�\��d�`y!�I�I�Ǭ��@�$d�h4�jxaBO��@��)IU���d��%���I���I�+� ���3�6ll������uu���+���˃���p���W ���s[Qxů} L�J��_�+3�X�vD���(䓇��_G�l4#ƌS�_�Ô�Fs?�뀎�:)7�CKB��gAd�C>��|�s}>�8"G�oN n�tG�n����G�,Ԡj
��B>���˝�p�[V�>D�w����ٳ���[�%��.�3ڈ��f����F�Vp��Wb��ga�;��{�mN"����KeU�a�Z�JLd�����'��E�@8�Rn��h�	_��ZU�d�is�deI��kE�m�x��7�m�T����L�� _*?+�&�G� pV޹���A������瀗s�0<�
�nd	��5�=��Y��s����+���O��劉��Ӫ�$&�P1R��ÇB�4�D�x�,bX��|@�G�7�pD�K���q�F8��RExi��-���rkb���*��%�k��3@����%���	eU�9 ����o��q��l4��TJ�i.P�����J��%�L����%m��[��I~ueef�o�M��;����/r�7G��Fd8�aswg{s�w0��{������}xm��ΆPnE���A�q��i��t�MX�c����C�1C��@�3�WIb����5�<�o}��Z�2��9|#�H؅=x�U7:�� � ���j�P��?v����3	�HP`<�C>'�و����wEC�l���|��c�[�jf�S'Ѓ"�)$s���3P$�0< �b����� ��D����>i;�8x��������5`E<��3�$�Z�pU�$@��x
�oA�����4r�s�覚ST�wP۳X̊���fC�B_@UK�Lx�S���3��LKȯV�+T�A��V�	�ņ~��VǬJ8�!*���V2���!���8?���J�`�7q�b��C�:3�T_��\��~+4���Vgmyu:��~��_⚛�i nNfs(��3�e��ۘ�;�0�R+�9&�η�4<���>h`�ɵ�
+��#��I�Gn�v�ytʗ+�k�:"ν� <ӱ\�q#� �yr��̺D b<,����`�/� ��L}����P�4+E(����N�c���ی�S]_�e��������q�H&�g>��c5�P���0��i�SC�}�����;Ky4?K���j�㈜yX��T`\�������d��Q�̱��=�o�N���ܜ����I�rӆr��B(6sϹאF�|A�z��WÀ�'�����`^rm{�Ktj�*օ�KͩH�U!K��K�=o�J�%����{��H!�����(M7&��q��&�*ą�.r�>\4���B%��w�fD�{�U� /^��Z:*̓��j>��5+$�8Ѐ4��e��f�T%���q�A��.�>�V>�f�fE#P�XF��k�3�C]浞h���eHi��7͓:/�
�$p�P9���/�0����(�D�a�oI���fs]4MLf�R�$p	#�r��&Q�!1<&R�Am?�'ĉ�$e� �/g��T�	c)h;i�]�m�T�o$pB���gR��}��БPAw��#	��NȽ.����&�1b����"T�.K��V�q��Yib,1!BN��S�~�%�7��1� �h�a(x�hΨg���#0NH&��K	�1�l��Ȋ�3:0S�����lj$Aؖ=���rV��b'�c8����=�a�;vJ�"Ʉ1"+��dM�]I1`��M��BJW��
��`QH�!�d����PsU��� ǚ��U�1�]K�8/2�ẘ��S����S �9H�32H�bjVUy�|�\�u\��a��l��f�|���I�WMtz��,�����2��1ӱ:�Y�0�O���{����V� ����ban�
���|�^ʧ�0����z���J��B�dMLUh���C�rq�=O���S��M�.IGpw&0��# }�Yj�41^�a��+��t�:ig�8��.�kY�����Q��4����b���+����:e�4 8v��j�OZ}�a���d4-X��̰p�tx�>b��P��7���6�/+Y������e��6�{
 ��UHU�f�`������!v�(��?I���<p�����:sɃ���t�wMAnFy`�)�.Q�O24���T����b��t�U\��ܝ���N@��O��w�
��W�oա���K<ׇ*ԡ�o�_��ߠ<T΄��_E�=�Ȥ�:�RD]LW�$�ߙ�:���ߥe����!�W������
J��/��M�.(�����wR֜�c��gO�E�7�_��`���0<:��_2��zT_��v�����Q�ݪ��zk�:�G����|T#+��G�u�-���᭵�"Q�ԛm X�?^n��Q����Gk����뫏V�mE�Z�����:���#dz|��L��|a��V��O���V%3t�8_a �4^(ʵ>)�:�\z9N���w�<���nO� di	�AXH�)'G扤
oB�9����p{� s�ls��;�hp1�VD�����L��T��I�
�qf>O��e� r`��. � �5�V\4��M�߱m��6.���m^J�e�w�>I5�S=��	��sB]��&�	v��
a�$1��+N�L���yE���ٳ,��"��]���,�b�	b�N2�'W2��x��:��&�/�
��d
�Jn��%'ݸ =2�4�j�����.�`�k��#�6�Ӝ5K\�+MN��Y� �b�Y�r�:�.�\U\\箄L�6V0��2mX��л(��J��_����^0\Y��=��u�;��ߕf���__��z�����M0�m��{���{�����a�p�����p���V��n65��=0��/�#ژh{M�9�Q���a��ƄR�*����
Ҙ%�S@3��ե�� �6E�ص3�����yV���=�z�;�����<���M��ދ�~ﰫ(�I/h@��讉�!\2�x>%6�X���P�]d^����` �P#�d�Nv�}�3"»
F\h&vdP.ƀ��T�0��8Ӂ	��jZ@���:�ˀ-�$��)�Q �˭-�:��ۿ��盢ٸ�
s�b:�mz����v�
�L�	�<��Af���3���S8!q<� �Yz��S����	l�����5.��3C�Q�jRs��^3&	�-|�d_�ޫ)?#ګW��g�AN#|�r�>0Đ��a�3�1 n~hJ|j~@]�ȟ��U��v�� ҩo�j]� �.�K�~�c���&�����\��
��5�X���7.�B�=���~�v1l|��g&�I��)�t�O�6_�l�#�?��e0e���� ��*�������RV`hR˂�!:��<����в����F˰�.H���$�gRnq�&�� :�g7�lU���w{��\G2Y*���B��((&�L�|��<�{�n~As5��(���1�f_�Z�)Lf{�"�9.U�n���?�@�ab�d]�Bm|9ɤV�{�v��E�ҧ�MB�m]\�6=:�³|�5�f���P�:����4���h(0�nV�u�7"h�.q| l"�)u�a%��,���@���B�|�I<����A�X��hςߛ_�a|ƣ�,BzN2�Q���6���n�2�ו�H	W���nY�ڪ�����W�D�2���Z`"ST�-�ߚ�Ç�*w�K<�	�o��B7�� FQ�����^�tP�c���'��K2A�o%gi��c]_̼�ƪi<�t�����nN��[l��u/o}H�'9n��>�:��:D���O�W�z�ݶ��k�Eb�0���88��;�k�>#��H�릒���3q�b�Z6��Y�N~puH3����
���_���~���1�%�{����?u��� %\B6X�����4�z���ApS�����L��n~�~#��\@�]��(95Z�������|>r�<��dL��8rBB?u\�YÇ�Y;�%4uc7P&~�c@��o�~@�c�t�҄t�ւ�/�e%�c�l��3��\<���Q�/"JL��X�&� D���������׈�I�G��wF.�툪b"r@*�W��՞Pd���`?���0�q���l���ߡe�s6&�π�wJ��
ɤBL�v���yM}������I�������]�|=��e������*�b-9d����޳�zj81��NQ��c���gi�+sV�b��������w��&@�O!ģ��sL�w�p^#&u�uӦ
��x�|R	��@M�S'���,�YF��B�[<�x��� �^ވ�����J�B.*���zܨ�ňȺZ� ��}|t�b�ZG>�'=y��g�*���f9]!�+�g�,JτB~pC��k��}��N�n��|���;S��Ws������﹟��1�����/��X�m�����&!�<!���B���ehb{G|�d�IP�o���;Y|1;��b��T}s|m"�%^\�������#�/��	�	|s�F�&�:��p�=�ȿ��dԮ%t��$_�܇@9�hj�Ѳ��; 3�����J��c�sv`�B����#�*�.���I��y�ӱ�m�����{��1�]����#	
�L|� �
I ��f�ۀ��{㍹��L+��R�k3n��K'B�G��󓔃���C�8�mor�h:`�vd���'_R�Y@�}f��s�O���gA#"����Dlc� "�R]��'��������U�V
et�`�&��G� ���LQIB��6UB�ć�q{�W_lw�?�'tO{�U�;������~vY�Z+�\l�gϟ�Ř],�U�<���ySP(v��c��,�>+�H�g2τ|O��XL4ѓMI��T�Z�}�^Q��l�b����0 ��8 F�����Fz   �1<�#�w�XǏ�|pZ_�S�H���V�<Z�9({��7�,��1U�Q������`��*�G�HM	έ�4�<¿.�#M&^I{
�u�9�_��&l0g�����n���i-��$R��^����(� ��,U2eX��a ��X��>�g
��T���T�^�1j%b+�� �H��4d������+H���ˎ�@�!��G7��\{���tOXm9��f-U�@�y��0�g�Y�1���y!C;����KW �f|a����6-dY�^I:���(���� ��������1��Ό����^� A~�Pp�����8�ku��.x�o�tEP;5!�bq]����b%R�(�u2Q��f�����	��Κ=�'1L䑵��e9�(���
����}�`'p���������pxz>N���+�
��!F��$EH�"F���Ggs׵���4�3����1Oš8ylcf��c�)r'����~\'o�tX�>Ȃ C�Ekّb��%�ExB� ���j�[����1�$�+Q�&��Iv�Q�B�	a�t�5� ]ԣ�F���9��}�e���m�&�ý�}��:u���3 ���$g+�8�a�1~�F7���2��ʊ^��S�q�d��k�1I�6�1K�@*��'�ݭd����D���JK����T�����2��̽B���~p�	Tf{W�,kGy.+�z"7��PH�-!���$��B��r=����o6sG�����%h�a�'I�A$r,�v&�J'�g�i��c�$���(y�>>>��M�.@ò8ga�����|���5T��p�K�ty��� R�ӓ�`p<�8~�����ӆ�{��v����d�)#�
2�ʩ�ԕC�s���F6H_�k`�Ww������v�}��O�	�>��8/�3�/-Զq��V��E$�<���Y�P�*�B��)�uoJB��q�f�ȿ��2�!��IZ�9\�s��,����U�v�	��S~�A-��^�������a,gO�`�D�ps����-k�������9��5��m������P�)MiJS�Ҕ�4�)MiJS�Ҕ�4�(B��n x  