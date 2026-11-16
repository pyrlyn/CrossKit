import Foundation

/// Java source of the preview renderer (compiled once with the JDK's javac, then run on the project's classpath).
enum PreviewRendererSource {
    static let className = "CrossKitPreviewRenderer"

    static let java = #"""
    // Written by CrossKit. Renders Compose Multiplatform @Preview functions to PNG with Compose Desktop's
    // ImageComposeScene. Pure reflection, so it compiles without the project's classpath and works across
    // Compose versions.
    //
    // Usage: java -cp <renderer>:<project runtime classpath> CrossKitPreviewRenderer <outDir> <spec>...
    // spec: id TAB class TAB method TAB widthDp TAB heightDp TAB density TAB background (AARRGGBB hex or "none")
    // Prints one line per spec: "CROSSKIT_PREVIEW <id> OK <width> <height>" or "CROSSKIT_PREVIEW <id> ERROR <message>".
    import java.awt.Color;
    import java.awt.Graphics2D;
    import java.awt.image.BufferedImage;
    import java.io.ByteArrayInputStream;
    import java.io.File;
    import java.lang.reflect.Constructor;
    import java.lang.reflect.InvocationTargetException;
    import java.lang.reflect.Method;
    import java.lang.reflect.Modifier;
    import java.lang.reflect.Proxy;
    import java.lang.reflect.UndeclaredThrowableException;
    import javax.imageio.ImageIO;

    public final class CrossKitPreviewRenderer {
        private static final int MAX_PIXELS = 2048;

        public static void main(String[] args) throws Exception {
            System.setProperty("java.awt.headless", "true");
            File out = new File(args[0]);
            out.mkdirs();
            ClassLoader loader = CrossKitPreviewRenderer.class.getClassLoader();
            for (int i = 1; i < args.length; i++) {
                String[] f = args[i].split("\t", -1);
                String id = f[0];
                try {
                    int[] size = render(loader, f[1], f[2], Integer.parseInt(f[3]), Integer.parseInt(f[4]),
                            Float.parseFloat(f[5]), f[6], new File(out, id + ".png"));
                    System.out.println("CROSSKIT_PREVIEW " + id + " OK " + size[0] + " " + size[1]);
                } catch (Throwable t) {
                    Throwable root = unwrap(t);
                    root.printStackTrace();
                    String message = (root.getClass().getName() + ": " + root.getMessage()).replace('\n', ' ');
                    System.out.println("CROSSKIT_PREVIEW " + id + " ERROR " + message);
                }
                System.out.flush();
            }
            // Compose and Skiko may leave non-daemon threads behind.
            System.exit(0);
        }

        private static Throwable unwrap(Throwable t) {
            while ((t instanceof InvocationTargetException || t instanceof UndeclaredThrowableException) && t.getCause() != null) {
                t = t.getCause();
            }
            return t;
        }

        static int[] render(ClassLoader loader, String className, String methodName, int widthDp, int heightDp, float density,
                            String background, File output) throws Exception {
            Class<?> owner = Class.forName(className, true, loader);
            Class<?> composer = Class.forName("androidx.compose.runtime.Composer", false, loader);
            Method preview = null;
            for (Method m : owner.getDeclaredMethods()) {
                Class<?>[] p = m.getParameterTypes();
                int c = indexOf(p, composer);
                if (m.getName().equals(methodName) && c >= 0 && trailingInts(p, c)) { preview = m; break; }
            }
            if (preview == null) {
                throw new NoSuchMethodException(className + "." + methodName + " is not a @Composable function (was the Compose compiler plugin applied?)");
            }
            preview.setAccessible(true);
            Object receiver = null;
            if (!Modifier.isStatic(preview.getModifiers())) {
                try {
                    receiver = owner.getField("INSTANCE").get(null);
                } catch (NoSuchFieldException e) {
                    Constructor<?> ctor = owner.getDeclaredConstructor();
                    ctor.setAccessible(true);
                    receiver = ctor.newInstance();
                }
            }
            final Method target = preview;
            final Object self = receiver;
            final Class<?>[] params = preview.getParameterTypes();
            final int composerIndex = indexOf(params, composer);
            Object unit = Class.forName("kotlin.Unit", true, loader).getField("INSTANCE").get(null);
            Class<?> function2 = Class.forName("kotlin.jvm.functions.Function2", false, loader);
            Object content = Proxy.newProxyInstance(loader, new Class<?>[] {function2}, (proxy, method, a) -> {
                switch (method.getName()) {
                    case "invoke": {
                        Object[] values = new Object[params.length];
                        for (int i = 0; i < params.length; i++) values[i] = defaultValue(params[i]);
                        values[composerIndex] = a[0];
                        values[composerIndex + 1] = 0;
                        // Any further ints are $changed/$default masks: ask for every parameter's default value.
                        for (int i = composerIndex + 2; i < params.length; i++) values[i] = -1;
                        target.invoke(self, values);
                        return unit;
                    }
                    case "hashCode": return System.identityHashCode(proxy);
                    case "equals": return proxy == a[0];
                    case "toString": return "CrossKitPreview(" + methodName + ")";
                    default: throw new UnsupportedOperationException(method.getName());
                }
            });

            Object densityValue = Class.forName("androidx.compose.ui.unit.DensityKt", true, loader)
                    .getMethod("Density", float.class, float.class).invoke(null, density, 1f);
            Object context;
            try {
                context = Class.forName("kotlinx.coroutines.Dispatchers", true, loader).getMethod("getUnconfined").invoke(null);
            } catch (ClassNotFoundException e) {
                context = Class.forName("kotlin.coroutines.EmptyCoroutineContext", true, loader).getField("INSTANCE").get(null);
            }
            Class<?> sceneClass = Class.forName("androidx.compose.ui.ImageComposeScene", true, loader);
            Constructor<?> sceneCtor = null;
            for (Constructor<?> c : sceneClass.getConstructors()) {
                Class<?>[] p = c.getParameterTypes();
                if (p.length == 5 && p[0] == int.class && p[1] == int.class && p[4] == function2) { sceneCtor = c; break; }
            }
            if (sceneCtor == null) throw new NoSuchMethodException("ImageComposeScene(int, int, Density, CoroutineContext, content) not found; is compose.desktop.currentOs on the classpath?");

            int width = widthDp > 0 ? Math.round(widthDp * density) : MAX_PIXELS;
            int height = heightDp > 0 ? Math.round(heightDp * density) : MAX_PIXELS;
            boolean crop = false;
            if (widthDp <= 0 || heightDp <= 0) {
                Object probe = sceneCtor.newInstance(width, height, densityValue, context, content);
                try {
                    Method calculate = null;
                    for (Method m : sceneClass.getMethods()) {
                        if (m.getName().startsWith("calculateContentSize") && m.getParameterCount() == 0 && m.getReturnType() == long.class) calculate = m;
                    }
                    if (calculate != null) {
                        long packed = (Long) calculate.invoke(probe);
                        int w = (int) (packed >> 32), h = (int) (packed & 0xffffffffL);
                        if (widthDp <= 0) width = Math.max(1, Math.min(w, MAX_PIXELS));
                        if (heightDp <= 0) height = Math.max(1, Math.min(h, MAX_PIXELS));
                    } else {
                        crop = true;
                    }
                } finally {
                    sceneClass.getMethod("close").invoke(probe);
                }
            }
            Object scene = sceneCtor.newInstance(width, height, densityValue, context, content);
            byte[] png;
            try {
                Object image = sceneClass.getMethod("render", long.class).invoke(scene, 0L);
                png = encodePNG(image, loader);
            } finally {
                sceneClass.getMethod("close").invoke(scene);
            }
            BufferedImage img = ImageIO.read(new ByteArrayInputStream(png));
            if (crop) img = cropTransparent(img);
            if (!background.equals("none")) {
                BufferedImage filled = new BufferedImage(img.getWidth(), img.getHeight(), BufferedImage.TYPE_INT_ARGB);
                Graphics2D g = filled.createGraphics();
                g.setColor(new Color((int) Long.parseLong(background, 16), true));
                g.fillRect(0, 0, img.getWidth(), img.getHeight());
                g.drawImage(img, 0, 0, null);
                g.dispose();
                img = filled;
            }
            ImageIO.write(img, "png", output);
            return new int[] {img.getWidth(), img.getHeight()};
        }

        private static byte[] encodePNG(Object image, ClassLoader loader) throws Exception {
            Class<?> imageClass = Class.forName("org.jetbrains.skia.Image", true, loader);
            Class<?> format = Class.forName("org.jetbrains.skia.EncodedImageFormat", true, loader);
            @SuppressWarnings({"unchecked", "rawtypes"})
            Object png = Enum.valueOf((Class) format, "PNG");
            Object data = null;
            for (Method m : imageClass.getMethods()) {
                Class<?>[] p = m.getParameterTypes();
                if (m.getName().equals("encodeToData$default") && p.length >= 3 && p[1] == format) {
                    Object[] values = new Object[p.length];
                    values[0] = image;
                    values[1] = png;
                    int maskIndex = p.length - 2;
                    for (int i = 2; i < maskIndex; i++) values[i] = 0;
                    values[maskIndex] = ~1;  // every parameter but the format takes its default
                    values[p.length - 1] = null;
                    data = m.invoke(null, values);
                    break;
                }
            }
            if (data == null) data = imageClass.getMethod("encodeToData", format, int.class).invoke(image, png, 100);
            if (data == null) throw new IllegalStateException("Skia could not encode the preview as PNG");
            return (byte[]) data.getClass().getMethod("getBytes").invoke(data);
        }

        private static BufferedImage cropTransparent(BufferedImage img) {
            int minX = img.getWidth(), minY = img.getHeight(), maxX = -1, maxY = -1;
            for (int y = 0; y < img.getHeight(); y++) {
                for (int x = 0; x < img.getWidth(); x++) {
                    if ((img.getRGB(x, y) >>> 24) != 0) {
                        minX = Math.min(minX, x); minY = Math.min(minY, y); maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
                    }
                }
            }
            if (maxX < 0) return img.getSubimage(0, 0, 1, 1);
            return img.getSubimage(0, 0, maxX + 1, maxY + 1);
        }

        private static int indexOf(Class<?>[] types, Class<?> type) {
            for (int i = 0; i < types.length; i++) if (types[i] == type) return i;
            return -1;
        }

        private static boolean trailingInts(Class<?>[] p, int composerIndex) {
            if (composerIndex + 1 >= p.length) return false;
            for (int i = composerIndex + 1; i < p.length; i++) if (p[i] != int.class) return false;
            return true;
        }

        private static Object defaultValue(Class<?> type) {
            if (!type.isPrimitive()) return null;
            if (type == boolean.class) return false;
            if (type == char.class) return '\0';
            if (type == long.class) return 0L;
            if (type == float.class) return 0f;
            if (type == double.class) return 0.0;
            if (type == byte.class) return (byte) 0;
            if (type == short.class) return (short) 0;
            return 0;
        }
    }
    """#
}
