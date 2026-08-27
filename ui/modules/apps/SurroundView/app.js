angular.module('beamng.apps')
.directive('surroundView', [function () {
  return {
    templateUrl: '/ui/modules/apps/SurroundView/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      var root = element[0]
      var views = root.querySelectorAll('.sv-camera')
      var rear = root.querySelector('.sv-rear')
      var canvas = root.querySelector('#svRearCanvas')
      var ctx = canvas ? canvas.getContext('2d') : null
      var statusText = root.querySelector('#svCameraStatus')

      for (var i = 0; i < views.length; i++) {
        views[i].classList.add('sv-camera--online')
      }

      function setStatus(state, message) {
        if (!statusText) return
        statusText.textContent = message || state || 'UNKNOWN'
        statusText.setAttribute('data-state', state || '')
      }

      function drawRgbFrame(frame) {
        if (!ctx || !frame || !frame.rgb) return

        try {
          var binary = atob(frame.rgb)
          var width = frame.width || 200
          var height = frame.height || 112
          var pixelCount = width * height

          if (binary.length < pixelCount * 3) {
            setStatus('error', 'FRAME SIZE ERROR')
            return
          }

          if (canvas.width !== width) canvas.width = width
          if (canvas.height !== height) canvas.height = height

          var image = ctx.createImageData(width, height)
          var dst = image.data
          var s = 0
          var d = 0

          for (var p = 0; p < pixelCount; p++) {
            dst[d++] = binary.charCodeAt(s++)
            dst[d++] = binary.charCodeAt(s++)
            dst[d++] = binary.charCodeAt(s++)
            dst[d++] = 255
          }

          ctx.putImageData(image, 0, 0)
          rear.classList.add('sv-camera--live')
          setStatus('live', 'REAR LIVE')
        } catch (err) {
          setStatus('error', 'FRAME DECODE ERROR')
          console.error('SurroundView rear frame error', err)
        }
      }

      scope.$on('SurroundViewStatus', function (event, data) {
        if (!data) return
        setStatus(data.state, data.message || data.state)
      })

      scope.$on('SurroundViewRearFrame', function (event, data) {
        drawRgbFrame(data)
      })

      setStatus('starting', 'STARTING REAR CAMERA…')
      bngApi.engineLua("extensions.load('surroundView'); extensions.surroundView.startRearCamera()")

      scope.$on('$destroy', function () {
        bngApi.engineLua("if extensions.surroundView then extensions.surroundView.stopRearCamera() end")
      })
    }
  }
}])
