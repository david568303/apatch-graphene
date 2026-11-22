# SPDX-License-Identifier: GPL-3.0-only
#
# R8 configuration for the Play Integrity hook dex (integrity/build_hook.sh).
#
# The dex is appended to framework.jar, so it lands on the bootclasspath of
# every process. The only fixed contract is Hooks.chain, called by name from
# the smali spliced into AndroidKeyStoreSpi (integrity/insert_hook.py) -- keep
# it, with that exact signature, and let R8 rename and repackage everything
# else into io.github.david568303.pi. The bundled BouncyCastle therefore keeps
# no org.bouncycastle.* names in the final dex and cannot shadow a copy an app
# ships on its own dexpath.

-keep public class io.github.david568303.pi.Hooks {
    public static java.security.cert.Certificate[] chain(java.lang.String);
}

# Flatten every surviving class (ours + BouncyCastle) into one private package.
-repackageclasses 'io.github.david568303.pi'
-allowaccessmodification
-dontoptimize

# BouncyCastle pulls in optional JCE/JavaMail/other references that android.jar
# does not have; none are on the paths the hook actually uses.
-dontwarn org.bouncycastle.**
-dontwarn javax.**
-dontwarn java.**
-dontwarn org.json.**
-dontnote **

# The hook reaches the host Application and SystemProperties reflectively; it
# names no obfuscatable class of its own by string, so no -keepnames is needed.
