package com.apkrunner.test;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.TextView;

public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        TextView text = new TextView(this);
        text.setText("APK Runner test app is running!");
        text.setTextSize(28);
        text.setGravity(Gravity.CENTER);
        text.setTextColor(Color.WHITE);
        text.setBackgroundColor(Color.rgb(20, 120, 60));
        setContentView(text);
    }
}
