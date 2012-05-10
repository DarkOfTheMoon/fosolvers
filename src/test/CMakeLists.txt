SET(tests_src tests.f90 showTestRst.f90)
ADD_EXECUTABLE(tests ${tests_src})
TARGET_LINK_LIBRARIES(tests fosolvers)

SET(test_src test.f90 showTestRst.f90)
ADD_EXECUTABLE(test ${test_src})
TARGET_LINK_LIBRARIES(test fosolvers)
ADD_CUSTOM_COMMAND(
  TARGET test
  POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_CURRENT_SOURCE_DIR}/grid.msh
                                   ${PROJECT_BINARY_DIR}/bin/grid.msh
)