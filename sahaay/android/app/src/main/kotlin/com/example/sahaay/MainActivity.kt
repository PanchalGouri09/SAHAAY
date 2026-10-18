package com.example.sahaay

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var placesChannel: PlacesChannel? = null
    private var pdfSaverChannel: PdfSaverChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        placesChannel = PlacesChannel(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        pdfSaverChannel = PdfSaverChannel(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun onDestroy() {
        placesChannel?.dispose()
        placesChannel = null
        pdfSaverChannel?.dispose()
        pdfSaverChannel = null
        super.onDestroy()
    }
}