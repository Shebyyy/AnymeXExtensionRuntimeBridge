package androidx.collection;

public class LruCache<K, V> extends android.util.LruCache<K, V> {

    public LruCache(int maxSize) {
        super(maxSize);
    }

    @Override
    protected int sizeOf(K key, V value) {
        return 1;
    }
}
