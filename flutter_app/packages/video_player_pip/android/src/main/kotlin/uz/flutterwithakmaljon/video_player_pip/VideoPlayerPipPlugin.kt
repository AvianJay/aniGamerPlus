package uz.flutterwithakmaljon.video_player_pip

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.util.Log
import android.util.Rational
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** VideoPlayerPipPlugin */
class VideoPlayerPipPlugin: FlutterPlugin, MethodCallHandler, ActivityAware {
  private val TAG = "VideoPlayerPipPlugin"
  
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private var activity: Activity? = null
  private var isInPipMode = false
  private var activityBinding: ActivityPluginBinding? = null
  private var componentCallback: android.content.ComponentCallbacks? = null
  
  // Cache of player ID to view mappings to improve performance for multiple calls
  private val playerViewCache = mutableMapOf<Int, View?>()
  
  // Track the active player ID to ensure PiP only works for video screen
  private var activePlayerId: Int? = null
  // Track if PiP was requested by user vs auto-triggered
  private var pipRequestedByUser = false
  
  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "video_player_pip")
    channel.setMethodCallHandler(this)
    context = flutterPluginBinding.applicationContext
    Log.d(TAG, "Plugin attached to engine")
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    Log.d(TAG, "Method called: ${call.method}")
    
    when (call.method) {
      "isPipSupported" -> {
        val supported = isPipSupported()
        Log.d(TAG, "PiP supported: $supported")
        result.success(supported)
      }
      "enterPipMode" -> {
        val playerId = call.argument<Int>("playerId")
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        Log.d(TAG, "Entering PiP mode for playerId: $playerId, width: $width, height: $height")
        
        if (playerId != null) {
          // Set active player ID when user explicitly requests PiP
          activePlayerId = playerId
          pipRequestedByUser = true
          val success = enterPipMode(playerId, width, height)
          Log.d(TAG, "Enter PiP result: $success")
          result.success(success)
        } else {
          Log.e(TAG, "Invalid argument: playerId is null")
          result.error("INVALID_ARGUMENT", "Player ID is required", null)
        }
      }
      "exitPipMode" -> {
        Log.d(TAG, "Exiting PiP mode, current state: $isInPipMode")
        // Clear active player ID when exiting PiP
        pipRequestedByUser = false
        val success = exitPipMode()
        if (success) {
          activePlayerId = null
        }
        Log.d(TAG, "Exit PiP result: $success")
        result.success(success)
      }
      "isInPipMode" -> {
        Log.d(TAG, "Checking if in PiP mode: $isInPipMode")
        result.success(isInPipMode)
      }
      else -> {
        Log.w(TAG, "Method not implemented: ${call.method}")
        result.notImplemented()
      }
    }
  }
  
  private fun isPipSupported(): Boolean {
    return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
  }
  
  private fun enterPipMode(playerId: Int, customWidth: Int?, customHeight: Int?): Boolean {
    if (!isPipSupported() || activity == null) {
      Log.d(TAG, "PiP not supported or activity is null")
      return false
    }
    
    try {
      // Clear cache if different player ID
      if (!playerViewCache.containsKey(playerId)) {
        Log.d(TAG, "Clearing player view cache for new playerId: $playerId")
        playerViewCache.clear()
      }
      
      // Find the video player view in the hierarchy
      val videoView = playerViewCache.getOrPut(playerId) { 
        Log.d(TAG, "Finding video player view for ID: $playerId")
        findVideoPlayerView(playerId) 
      }
      
      if (videoView == null) {
        Log.e(TAG, "Could not find video player view for ID: $playerId")
        return false
      }
      
      Log.d(TAG, "Found video view: ${videoView.javaClass.simpleName}, width: ${videoView.width}, height: ${videoView.height}")
      
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        // Use custom dimensions if provided, otherwise use the view's dimensions
        val width = customWidth ?: videoView.width
        val height = customHeight ?: videoView.height
        
        Log.d(TAG, "Using dimensions for PiP: width=$width, height=$height")
        
        // Default to 16:9 if dimensions are invalid or too small
        val aspectRatio = if (width > 0 && height > 0 && width >= 100 && height >= 100) {
          Rational(width, height)
        } else {
          Log.d(TAG, "Using default 16:9 aspect ratio as dimensions are invalid")
          Rational(16, 9)
        }
        
        val paramsBuilder = PictureInPictureParams.Builder()
            .setAspectRatio(aspectRatio)
        
        // Set source rect for smoother transitions on Android 12+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val location = IntArray(2)
            videoView.getLocationInWindow(location)
            val sourceRectHint = android.graphics.Rect(
                location[0], location[1],
                location[0] + videoView.width,
                location[1] + videoView.height
            )
            paramsBuilder.setSourceRectHint(sourceRectHint)
            Log.d(TAG, "Setting sourceRectHint to $sourceRectHint")
        }
        
        // Set is seamless for smoother transitions on Android 12+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            paramsBuilder.setSeamlessResizeEnabled(true)
            Log.d(TAG, "Setting seamlessResizeEnabled to true")
        }
        
        val params = paramsBuilder.build()
        
        // Enter PiP mode
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val result = activity?.enterPictureInPictureMode(params) ?: false
            Log.d(TAG, "enterPictureInPictureMode result: $result")
            return result
        }
      }
      
      return false
    } catch (e: Exception) {
      Log.e(TAG, "Error entering PiP mode", e)
      return false
    }
  }
  
  private fun exitPipMode(): Boolean {
    if (!isPipSupported() || activity == null) {
      Log.d(TAG, "Cannot exit PiP: not supported or activity is null")
      return false
    }
    
    try {
      if (isInPipMode) {
        Log.d(TAG, "Currently in PiP mode, attempting to exit")
        
        // For Android 10+, we can use a better approach to exit PiP mode
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          activity?.let {
            // This will bring the app back to full screen
            Log.d(TAG, "Using Android 10+ approach: changing orientation")
            it.requestedOrientation = it.requestedOrientation
          }
        } else {
          // For older versions, moving task to back and then bringing it forward is a workaround
          Log.d(TAG, "Using pre-Android 10 approach: move task to back and relaunch")
          activity?.moveTaskToBack(false)
          activity?.let {
            it.startActivity(it.packageManager.getLaunchIntentForPackage(it.packageName))
          }
        }
        
        // Reset PiP state
        isInPipMode = false
        pipRequestedByUser = false
        
        return true
      }
      Log.d(TAG, "Not in PiP mode, cannot exit")
      return false
    } catch (e: Exception) {
      Log.e(TAG, "Error exiting PiP mode", e)
      return false
    }
  }
  
  /**
   * Finds the video player view for the given player ID.
   * This is implemented based on analysis of how video_player creates its views.
   */
  private fun findVideoPlayerView(playerId: Int): View? {
    if (activity == null) {
      Log.d(TAG, "Activity is null, cannot find video player view")
      return null
    }
    
    val rootView = activity?.findViewById<ViewGroup>(android.R.id.content)?.getChildAt(0)
    Log.d(TAG, "Starting view search from root: ${rootView?.javaClass?.simpleName}")
    
    // Try to find a tag or ID that might match the player ID
    return findVideoPlayerViewRecursively(rootView, playerId)
  }
  
  /**
   * Recursively searches the view hierarchy for the SurfaceView or TextureView used by video_player.
   * Tries to match by playerID and also looks for platform view containers.
   */
  private fun findVideoPlayerViewRecursively(view: View?, playerId: Int, depth: Int = 0): View? {
    if (view == null) return null
    
    val indentation = " ".repeat(depth * 2)  // For logging hierarchy
    val viewClassName = view.javaClass.simpleName
    Log.v(TAG, "$indentation Checking view: $viewClassName, tag: ${view.tag}")
    
    // Check if the view has a tag matching our player ID
    if (view.tag != null && view.tag is String && (view.tag as String).contains("$playerId")) {
      Log.d(TAG, "$indentation Found view with matching tag: ${view.tag}")
      return view
    }
    
    // Check if this is a SurfaceView (what video_player uses in platform view mode)
    if (view is SurfaceView) {
      Log.v(TAG, "$indentation Found SurfaceView")
      
      // This could be our video view
      val parent = view.parent as? View
      if (isFlutterPlatformView(parent)) {
        Log.d(TAG, "$indentation SurfaceView's parent is a platform view")
        
        // Check if we can find any references to the player ID in the view hierarchy
        if (parent?.tag != null && parent.tag.toString().contains("$playerId")) {
          Log.d(TAG, "$indentation Platform view has matching player ID tag: ${parent.tag}")
          return view
        }
        
        // If we can't find a direct reference but this is the only video view, use it
        Log.d(TAG, "$indentation Using SurfaceView as fallback (no specific ID match)")
        return view
      }
    }
    
    // Check if it's a platform view with a SurfaceView child
    if (isFlutterPlatformView(view)) {
      Log.v(TAG, "$indentation Found Flutter platform view: $viewClassName")
      
      if (view is ViewGroup) {
        for (i in 0 until view.childCount) {
          val child = view.getChildAt(i)
          if (child is SurfaceView) {
            Log.d(TAG, "$indentation Found SurfaceView child of platform view")
            return child
          }
        }
      }
    }
    
    // Recursively check children
    if (view is ViewGroup) {
      val childCount = view.childCount
      Log.v(TAG, "$indentation Checking $childCount children of $viewClassName")
      
      for (i in 0 until childCount) {
        val found = findVideoPlayerViewRecursively(view.getChildAt(i), playerId, depth + 1)
        if (found != null) return found
      }
    }
    
    // If we've checked everything and still can't find a match, return the first SurfaceView
    // This is a fallback for when we can't find a direct match
    if (view is ViewGroup && playerId != -1) {
      var firstSurfaceView: SurfaceView? = null
      
      for (i in 0 until view.childCount) {
        val child = view.getChildAt(i)
        if (child is SurfaceView && firstSurfaceView == null) {
          firstSurfaceView = child
          Log.v(TAG, "$indentation Found first SurfaceView as fallback")
        }
      }
      
      if (firstSurfaceView != null) {
        Log.d(TAG, "$indentation Using first SurfaceView as fallback")
        return firstSurfaceView
      }
    }
    
    return null
  }
  
  /**
   * Checks if the view is a Flutter platform view.
   */
  private fun isFlutterPlatformView(view: View?): Boolean {
    if (view == null) return false
    
    // The class name for platform views contains "PlatformView"
    val className = view.javaClass.name
    val isPlatformView = className.contains("PlatformView") && !className.contains("Factory")
    if (isPlatformView) {
      Log.v(TAG, "Identified Flutter platform view: $className")
    }
    return isPlatformView
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    Log.d(TAG, "Plugin detached from engine")
    channel.setMethodCallHandler(null)
    playerViewCache.clear()
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    Log.d(TAG, "Plugin attached to activity")
    activity = binding.activity
    activityBinding = binding
    
    // Set up PiP mode change listener
    setupPipModeChangeListener(binding)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    Log.d(TAG, "Plugin detached from activity for config changes")
    cleanupPipModeChangeListener()
    activity = null
    activityBinding = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    Log.d(TAG, "Plugin reattached to activity for config changes")
    activity = binding.activity
    activityBinding = binding
    
    // Re-set up PiP mode change listener
    setupPipModeChangeListener(binding)
  }

  override fun onDetachedFromActivity() {
    Log.d(TAG, "Plugin detached from activity")
    cleanupPipModeChangeListener()
    activity = null
    activityBinding = null
    playerViewCache.clear()
    
    // Reset PiP state on detach
    isInPipMode = false
    activePlayerId = null
    pipRequestedByUser = false
  }
  
  private fun setupPipModeChangeListener(binding: ActivityPluginBinding) {
    Log.d(TAG, "Setting up PiP mode change listener")
    binding.addActivityResultListener { requestCode, resultCode, data ->
      // Update PiP state on activity result as a fallback mechanism
      Log.v(TAG, "Activity result received: requestCode=$requestCode, resultCode=$resultCode")
      updatePipState()
      false // Not consuming the result
    }
    
    // Use Configuration.onPictureInPictureModeChanged for API 26+
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      // Store the callback to properly clean it up later
      componentCallback = object : android.content.ComponentCallbacks {
        override fun onConfigurationChanged(newConfig: Configuration) {
          val isInPictureInPictureMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity?.isInPictureInPictureMode ?: false
          } else {
            false
          }
          
          Log.d(TAG, "Configuration changed: PiP mode = $isInPictureInPictureMode (was $isInPipMode)")
          
          if (isInPipMode != isInPictureInPictureMode) {
            isInPipMode = isInPictureInPictureMode
            
            // If PiP mode is exited, clear the active player ID
            if (!isInPipMode) {
              activePlayerId = null
              pipRequestedByUser = false
            }
            
            notifyPipModeChanged()
          }
        }
        
        override fun onLowMemory() {
          // No implementation needed
          Log.d(TAG, "Low memory warning received")
        }
      }
      
      activity?.registerComponentCallbacks(componentCallback)
    }
  }
  
  private fun cleanupPipModeChangeListener() {
    Log.d(TAG, "Cleaning up PiP mode change listener")
    
    // Clean up component callbacks to prevent memory leaks
    componentCallback?.let {
      activity?.unregisterComponentCallbacks(it)
      componentCallback = null
    }
    
    activityBinding = null
  }
  
  private fun updatePipState() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val newPipState = activity?.isInPictureInPictureMode ?: false
      Log.d(TAG, "Updating PiP state: current=$isInPipMode, new=$newPipState")
      
      if (newPipState != isInPipMode) {
        isInPipMode = newPipState
        
        // If exiting PiP mode, reset the player ID
        if (!isInPipMode) {
          activePlayerId = null
          pipRequestedByUser = false
        }
        
        notifyPipModeChanged()
      }
    }
  }
  
  private fun notifyPipModeChanged() {
    try {
      Log.d(TAG, "Notifying Flutter of PiP mode change: $isInPipMode")
      channel.invokeMethod("pipModeChanged", mapOf(
          "isInPipMode" to isInPipMode
      ))
    } catch (e: Exception) {
      Log.e(TAG, "Error notifying PiP mode change", e)
    }
  }
}
