package com.shitmof.private_manga_reader;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.nio.file.Files;
import java.util.Arrays;

/** 不依赖 Android 设备的实际文件 I/O 回归，可用 JDK 17 的 javac/java 执行。 */
public final class MountArchiveCacheTest {
    public static void main(String[] args) throws Exception {
        File root = Files.createTempDirectory("shihuage-mount-cache-test-").toFile();
        try {
            MountArchiveCache cache = new MountArchiveCache(root, 1024, () -> Long.MAX_VALUE);
            File first = cache.materialize("content://book", "size:time-1", 3, false,
                    () -> new ByteArrayInputStream(new byte[]{1, 2, 3}));
            File updated = cache.materialize("content://book", "size:time-2", 3, false,
                    () -> new ByteArrayInputStream(new byte[]{4, 5, 6}));
            check(Arrays.equals(Files.readAllBytes(updated.toPath()), new byte[]{4, 5, 6}), "来源版本更新必须读取新内容");
            check(!first.equals(updated), "不同版本应有不同缓存标识");
            System.out.println("PASS: versioned content refresh");
            // 实际文件字节合计受到预算约束，而不是只限制文件个数。
            MountArchiveCache small = new MountArchiveCache(root, 5, () -> Long.MAX_VALUE);
            small.materialize("content://third", "v1", 3, false,
                    () -> new ByteArrayInputStream(new byte[]{7, 8, 9}));
            long used = Arrays.stream(root.listFiles()).filter(f -> f.getName().endsWith(".zip"))
                    .mapToLong(File::length).sum();
            check(used <= 5, "缓存必须按总字节裁剪");
            boolean rejected = false;
            try {
                small.materialize("content://too-large", "v1", 8, false,
                        () -> new ByteArrayInputStream(new byte[8]));
            } catch (java.io.IOException expected) { rejected = true; }
            check(rejected, "大于预算的压缩包应在复制前拒绝");
            check(Arrays.stream(root.listFiles()).noneMatch(f -> f.getName().endsWith(".part")), "失败不得留下半文件");
            System.out.println("PASS: byte budget and oversize rejection");
            cache.clear();
            cache.materialize("content://unknown", null, 3, false,
                    () -> new ByteArrayInputStream(new byte[]{1, 1, 1}));
            File unknown = new MountArchiveCache(root, 1024, () -> Long.MAX_VALUE)
                    .materialize("content://unknown", null, 3, false,
                            () -> new ByteArrayInputStream(new byte[]{2, 2, 2}));
            check(Arrays.equals(Files.readAllBytes(unknown.toPath()), new byte[]{2, 2, 2}), "未知修改时间不能跨读取会话复用旧数据");
            File refreshed = cache.materialize("content://unknown", null, 3, true,
                    () -> new ByteArrayInputStream(new byte[]{3, 3, 3}));
            check(Arrays.equals(Files.readAllBytes(refreshed.toPath()), new byte[]{3, 3, 3}), "重新索引必须强制更新未知版本");
            System.out.println("PASS: unknown revision and explicit refresh");
            boolean[] closed = {false};
            try {
                cache.materialize("content://broken", "v1", 0, false,
                        () -> new java.io.InputStream() {
                            int count = 0;
                            @Override public int read() throws java.io.IOException {
                                if (count++ == 0) return 1;
                                throw new java.io.IOException("测试断流");
                            }
                            @Override public void close() { closed[0] = true; }
                        });
                throw new AssertionError("中断应报告失败");
            } catch (java.io.IOException expected) { }
            check(closed[0], "失败必须关闭输入流");
            check(Arrays.stream(root.listFiles()).noneMatch(f -> f.getName().endsWith(".part")), "中断半文件必须清理");
            System.out.println("PASS: interrupted copy cleanup");
            boolean[] opened = {false};
            try {
                new MountArchiveCache(root, 1024, () -> 0).materialize("content://no-space", "v1", 3, false,
                        () -> { opened[0] = true; return new ByteArrayInputStream(new byte[]{1, 2, 3}); });
                throw new AssertionError("空间不足应事前拒绝");
            } catch (java.io.IOException expected) { }
            check(!opened[0], "空间不足不能先下载再报错");
            File unrelated = new File(root, "not-owned.cbz");
            Files.write(unrelated.toPath(), new byte[]{9});
            cache.clear();
            check(unrelated.isFile(), "清理必须保留非挂载缓存文件");
            System.out.println("PASS: free-space preflight and clear scope");
            for (int index = 0; index < 8; index++) {
                cache.materialize("content://count/" + index, "v1", 1, false,
                        () -> new ByteArrayInputStream(new byte[]{1}));
            }
            check(Arrays.stream(root.listFiles()).filter(f -> f.getName().endsWith(".zip")).count() <= 6, "条目数量仍应受控");
            System.out.println("PASS: entry count and byte budgets coexist");
        } finally {
            for (File file : root.listFiles()) file.delete();
            root.delete();
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
