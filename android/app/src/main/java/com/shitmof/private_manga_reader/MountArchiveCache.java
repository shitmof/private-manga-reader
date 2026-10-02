package com.shitmof.private_manga_reader;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.function.LongSupplier;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashSet;
import java.util.Set;

/** SAF 文档流的可重建压缩包缓存；所有调用由上层挂载 I/O 锁串行化。 */
public final class MountArchiveCache {
    @FunctionalInterface
    public interface Source { InputStream open() throws IOException; }
    private final File directory;
    private long budgetBytes;
    private final LongSupplier freeBytes;
    private final Set<String> sessionReady = new HashSet<>();
    private static final long SPACE_RESERVE = 16L * 1024 * 1024;

    public MountArchiveCache(File directory, long budgetBytes, LongSupplier freeBytes) {
        this.directory = directory;
        this.budgetBytes = budgetBytes;
        this.freeBytes = freeBytes;
    }

    public File materialize(String uri, String revision, long expectedBytes,
            boolean refresh, Source source) throws IOException {
        if (expectedBytes > budgetBytes) throw new IOException("压缩包大于挂载缓存预算，请提高预算或导入到本地");
        String digest = digest(uri + "\n" + (revision == null ? "" : revision));
        File target = new File(directory, digest + ".zip");
        if (!refresh && target.isFile() && target.length() > 0 &&
                (expectedBytes <= 0 || target.length() == expectedBytes) &&
                (revision != null || sessionReady.contains(digest))) {
            target.setLastModified(System.currentTimeMillis());
            prune(0, target);
            return target;
        }
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("无法创建挂载缓存目录");
        if (target.exists() && !target.delete()) throw new IOException("无法清理旧挂载缓存");
        for (File file : ownedFiles()) {
            if (file.getName().endsWith(".part") && !file.delete()) throw new IOException("无法清理中断的挂载缓存");
        }
        prune(Math.max(expectedBytes, 0), null);
        requireSpace(Math.max(expectedBytes, 0));
        File staging = new File(directory, digest + ".part");
        try {
            try (InputStream input = source.open(); OutputStream output = new FileOutputStream(staging)) {
                if (input == null) throw new IOException("无法读取原压缩包");
                byte[] buffer = new byte[64 * 1024];
                int count;
                long written = 0;
                long nextSpaceCheck = 0;
                while ((count = input.read(buffer)) != -1) {
                    if (count > budgetBytes - written) throw new IOException("压缩包超过挂载缓存预算，已停止读取");
                    if (expectedBytes <= 0 || written + count > expectedBytes) {
                        prune(written + count, null);
                    }
                    if (written >= nextSpaceCheck) {
                        prune(Math.max(expectedBytes, written + count), null);
                        requireSpace(count);
                        nextSpaceCheck = written + 4L * 1024 * 1024;
                    }
                    output.write(buffer, 0, count);
                    written += count;
                }
                if (written == 0 || (expectedBytes > 0 && written != expectedBytes)) {
                    throw new IOException("原压缩包读取不完整或已变化，请刷新书库后重试");
                }
            }
            if (target.exists() && !target.delete()) throw new IOException("无法替换旧挂载缓存");
            if (!staging.renameTo(target)) throw new IOException("无法提交挂载缓存");
            target.setLastModified(System.currentTimeMillis());
            sessionReady.add(digest);
            prune(0, target);
            return target;
        } finally {
            if (staging.exists()) staging.delete();
        }
    }

    public long bytes() throws IOException {
        long total = 0;
        for (File file : ownedFiles()) total += file.length();
        return total;
    }

    public void clear() throws IOException {
        for (File file : ownedFiles()) {
            if (!file.delete() && file.exists()) throw new IOException("部分挂载缓存无法删除，请稍后重试");
        }
        sessionReady.clear();
    }

    public void setBudget(long bytes) throws IOException {
        if (bytes <= 0) throw new IllegalArgumentException("缓存预算必须大于零");
        long previous = budgetBytes;
        budgetBytes = bytes;
        try { prune(0, null); }
        catch (IOException error) {
            budgetBytes = previous;
            throw error;
        }
    }

    private File[] ownedFiles() throws IOException {
        File[] files = directory.listFiles(file -> {
            if (!file.isFile() || !file.getName().matches("[a-f0-9]{40}\\.(zip|part)")) return false;
            try { return file.getCanonicalFile().getParentFile().equals(directory.getCanonicalFile()); }
            catch (IOException invalid) { return false; }
        });
        if (files == null && directory.exists()) throw new IOException("无法读取挂载缓存目录");
        return files == null ? new File[0] : files;
    }

    private void prune(long pendingBytes, File preserve) throws IOException {
        File[] files = Arrays.stream(ownedFiles()).filter(f -> f.getName().endsWith(".zip"))
                .sorted(Comparator.comparingLong(File::lastModified)).toArray(File[]::new);
        long used = Arrays.stream(files).mapToLong(File::length).sum();
        int count = files.length;
        for (File file : files) {
            if (used + pendingBytes <= budgetBytes && count <= (pendingBytes > 0 ? 5 : 6)) break;
            if (file.equals(preserve)) continue;
            long length = file.length();
            if (!file.delete() && file.exists()) throw new IOException("无法释放挂载缓存空间");
            used -= length;
            count--;
        }
        if (used + pendingBytes > budgetBytes) throw new IOException("挂载缓存预算不足");
    }

    private void requireSpace(long additionalBytes) throws IOException {
        long available = freeBytes.getAsLong();
        if (available < SPACE_RESERVE || additionalBytes > available - SPACE_RESERVE) {
            throw new IOException("手机剩余空间不足，已停止复制挂载压缩包");
        }
    }

    private static String digest(String value) {
        try {
            byte[] bytes = MessageDigest.getInstance("SHA-1").digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder result = new StringBuilder();
            for (byte item : bytes) result.append(String.format("%02x", item & 0xff));
            return result.toString();
        } catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
}
