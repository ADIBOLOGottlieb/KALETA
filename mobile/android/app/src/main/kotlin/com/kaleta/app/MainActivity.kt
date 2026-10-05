package com.kaleta.app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Reçoit le texte partagé par l'app Google Maps (« Partager » → KALETA, ACTION_SEND
 * text/plain) et le transmet à Flutter par le canal `kaleta/share` :
 * - `getInitialSharedText` : texte reçu au lancement de l'app (renvoyé une seule fois, puis null) ;
 * - `sharedText` (appelé côté Dart) : partage reçu alors que l'app est déjà ouverte.
 */
class MainActivity : FlutterActivity() {
    private var shareChannel: MethodChannel? = null
    private var initialSharedText: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Lu avant super.onCreate : configureFlutterEngine est appelé pendant super.onCreate.
        // Pas de relecture après une recréation de l'activité ou un lancement depuis l'historique.
        val launchIntent: Intent? = intent
        if (savedInstanceState == null && launchIntent != null &&
            (launchIntent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
        ) {
            initialSharedText = extractSharedText(launchIntent)
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialSharedText" -> {
                    val text = initialSharedText
                    initialSharedText = null
                    result.success(text)
                }
                else -> result.notImplemented()
            }
        }
        shareChannel = channel
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        shareChannel?.setMethodCallHandler(null)
        shareChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractSharedText(intent) ?: return
        val channel = shareChannel
        if (channel != null) {
            channel.invokeMethod("sharedText", text)
        } else {
            // Moteur pas encore prêt : Flutter le récupérera avec getInitialSharedText.
            initialSharedText = text
        }
    }

    /** Texte partagé (EXTRA_SUBJECT puis EXTRA_TEXT), ou null si ce n'est pas un partage de texte. */
    private fun extractSharedText(intent: Intent): String? {
        if (intent.action != Intent.ACTION_SEND) return null
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val subject = intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()?.trim().orEmpty()
        val combined = when {
            subject.isEmpty() -> text
            text.isEmpty() -> subject
            text.contains(subject) -> text
            else -> subject + "\n" + text
        }
        return combined.ifEmpty { null }
    }

    companion object {
        private const val CHANNEL = "kaleta/share"
    }
}
