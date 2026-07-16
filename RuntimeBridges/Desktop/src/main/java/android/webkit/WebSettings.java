package android.webkit;

public class WebSettings {
    public void setJavaScriptEnabled(boolean flag) {}
    public void setDomStorageEnabled(boolean flag) {}
    public void setDatabaseEnabled(boolean flag) {}
    public void setUseWideViewPort(boolean flag) {}
    public void setLoadWithOverviewMode(boolean flag) {}
    public void setCacheMode(int mode) {}
    public void setUserAgentString(String ua) {}
    public String getUserAgentString() { return ""; }
    public void setBlockNetworkImage(boolean flag) {}
    public void setBlockNetworkLoads(boolean flag) {}
    public void setSupportZoom(boolean flag) {}
    public void setBuiltInZoomControls(boolean flag) {}
    public void setDisplayZoomControls(boolean flag) {}
    public void setLoadsImagesAutomatically(boolean flag) {}
    public void setMixedContentMode(int mode) {}
    public void setAllowFileAccess(boolean flag) {}
    public void setAllowContentAccess(boolean flag) {}
    public void setGeolocationEnabled(boolean flag) {}
    public void setMediaPlaybackRequiresUserGesture(boolean flag) {}
    public void setTextZoom(int textZoom) {}
    public int getTextZoom() { return 100; }
    public void setSafeBrowsingEnabled(boolean flag) {}
    public boolean getSafeBrowsingEnabled() { return false; }
}
