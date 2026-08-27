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

      for (var i = 0; i < views.length; i++) {
        views[i].classList.add('sv-camera--online')
      }

      scope.$on('$destroy', function () {
        // Camera cleanup will be added when live BeamNG camera feeds are implemented.
      })
    }
  }
}])
